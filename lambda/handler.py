import json
import logging
import os
import uuid
from datetime import datetime, timezone
import boto3
from boto3.dynamodb.conditions import Key
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

AWS_REGION = os.environ["AWS_REGION"]
bedrock_agent = boto3.client("bedrock-agent-runtime", region_name=AWS_REGION)
bedrock_runtime = boto3.client("bedrock-runtime", region_name=AWS_REGION)
dynamodb = boto3.resource("dynamodb", region_name=AWS_REGION)
table = dynamodb.Table(os.environ["TABLE_NAME"])

KB_ID = os.environ["KB_ID"]
MODEL_ARN = os.environ["MODEL_ARN"]
GUARDRAIL_ID = os.environ["GUARDRAIL_ID"]
GUARDRAIL_VERSION = os.environ["GUARDRAIL_VERSION"]
KB_MODE = os.environ.get("KB_MODE", "vector").lower()
MEMORY_MODE = os.environ.get("MEMORY_MODE", "single").lower()
HISTORY_LIMIT = int(os.environ.get("HISTORY_LIMIT", "6"))


def _json_response(status_code, payload):
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(payload),
    }


def _load_history(session_id):
    """Load the most recent turns for a session from DynamoDB in chronological order."""
    if MEMORY_MODE != "multi":
        return []
    try:
        resp = table.query(
            KeyConditionExpression=Key("session_id").eq(session_id),
            ScanIndexForward=False,
            Limit=HISTORY_LIMIT,
        )
        items = resp.get("Items", [])
        items.reverse()
        return items
    except ClientError:
        logger.exception("Failed to load chat history for session %s", session_id)
        return []


def _query_vector_kb(prompt, history):
    """Query a vector-store Knowledge Base (e.g. S3 Vectors) via retrieve_and_generate."""
    query_text = prompt
    if history:
        turns = "\n".join(
            f"User: {item.get('prompt', '')}\nAssistant: {item.get('answer', '')}"
            for item in history
        )
        query_text = f"Conversation history:\n{turns}\n\nCurrent question: {prompt}"

    response = bedrock_agent.retrieve_and_generate(
        input={"text": query_text},
        retrieveAndGenerateConfiguration={
            "type": "KNOWLEDGE_BASE",
            "knowledgeBaseConfiguration": {
                "knowledgeBaseId": KB_ID,
                "modelArn": MODEL_ARN,
                "generationConfiguration": {
                    "guardrailConfiguration": {
                        "guardrailId": GUARDRAIL_ID,
                        "guardrailVersion": GUARDRAIL_VERSION,
                    }
                },
            },
        },
    )

    answer = response["output"]["text"]
    guardrail_action = response.get("guardrailAction", "NONE")
    sources = []
    for citation in response.get("citations", []):
        for ref in citation.get("retrievedReferences", []):
            uri = ref.get("location", {}).get("s3Location", {}).get("uri")
            if uri and uri not in sources:
                sources.append(uri)
    return answer, guardrail_action, sources


def _query_managed_kb(prompt, history):
    """Query a Managed Knowledge Base via retrieve + converse."""
    retrieval = bedrock_agent.retrieve(
        knowledgeBaseId=KB_ID,
        retrievalQuery={"text": prompt},
        retrievalConfiguration={
            "managedSearchConfiguration": {
                "numberOfResults": 5,
            }
        },
    )

    chunks = []
    sources = []
    for result in retrieval.get("retrievalResults", []):
        text = result.get("content", {}).get("text")
        if text:
            chunks.append(text)
        uri = result.get("location", {}).get("s3Location", {}).get("uri")
        if uri and uri not in sources:
            sources.append(uri)

    context_block = "\n\n---\n\n".join(chunks) if chunks else "No relevant documents found."

    messages = []
    for item in history:
        if item.get("prompt"):
            messages.append({"role": "user", "content": [{"text": item["prompt"]}]})
        if item.get("answer"):
            messages.append({"role": "assistant", "content": [{"text": item["answer"]}]})

    messages.append(
        {
            "role": "user",
            "content": [{"text": f"Context:\n{context_block}\n\nQuestion: {prompt}"}],
        }
    )

    converse_resp = bedrock_runtime.converse(
        modelId=MODEL_ARN,
        system=[
            {
                "text": (
                    "You are a helpful assistant. Answer the user's question using only "
                    "the provided knowledge base context and prior conversation history. "
                    "If the context does not contain the answer, say you do not have enough information."
                )
            }
        ],
        messages=messages,
        guardrailConfig={
            "guardrailIdentifier": GUARDRAIL_ID,
            "guardrailVersion": GUARDRAIL_VERSION,
        },
    )

    content_blocks = converse_resp.get("output", {}).get("message", {}).get("content", [])
    answer = "".join(block.get("text", "") for block in content_blocks)
    guardrail_action = (
        "INTERVENED"
        if converse_resp.get("stopReason") == "guardrail_intervened"
        else "NONE"
    )
    return answer, guardrail_action, sources


def lambda_handler(event, context):
    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _json_response(400, {"error": "Invalid JSON in request body"})

    if not isinstance(body, dict):
        return _json_response(400, {"error": "Request body must be a JSON object"})

    prompt = str(body.get("prompt", "")).strip()
    session_id = body.get("session_id") or str(uuid.uuid4())

    if not prompt:
        return _json_response(400, {"error": "prompt is required"})

    history = _load_history(session_id)

    try:
        if KB_MODE == "managed":
            answer, guardrail_action, sources = _query_managed_kb(prompt, history)
        elif KB_MODE == "vector":
            answer, guardrail_action, sources = _query_vector_kb(prompt, history)
        else:
            return _json_response(500, {"error": f"Unsupported KB_MODE: {KB_MODE}"})
    except ClientError as exc:
        err = exc.response.get("Error", {})
        code = err.get("Code", "ClientError")
        msg = err.get("Message", str(exc))
        logger.exception("Bedrock call failed (%s): %s", code, msg)
        status = 429 if code == "ThrottlingException" else 502
        return _json_response(status, {"error": code, "message": msg})

    try:
        table.put_item(
            Item={
                "session_id": session_id,
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "prompt": prompt,
                "answer": answer,
                "guardrail_action": guardrail_action,
                "sources": sources,
            }
        )
    except ClientError:
        # Don't fail the user's chat response if audit logging has a transient error
        logger.exception("Failed to write chat turn to DynamoDB for session %s", session_id)

    return _json_response(
        200,
        {
            "session_id": session_id,
            "answer": answer,
            "guardrail_action": guardrail_action,
            "sources": sources,
        },
    )
