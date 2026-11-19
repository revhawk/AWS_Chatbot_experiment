import json
import os
import uuid
from datetime import datetime, timezone
import boto3

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


def _query_vector_kb(prompt):
    """Query a vector-store Knowledge Base (e.g. S3 Vectors) via retrieve_and_generate."""
    response = bedrock_agent.retrieve_and_generate(
        input={"text": prompt},
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


def _query_managed_kb(prompt):
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

    converse_resp = bedrock_runtime.converse(
        modelId=MODEL_ARN,
        system=[
            {
                "text": (
                    "You are a helpful assistant. Answer the user's question using only "
                    "the provided knowledge base context. If the context does not contain "
                    "the answer, say you do not have enough information."
                )
            }
        ],
        messages=[
            {
                "role": "user",
                "content": [
                    {"text": f"Context:\n{context_block}\n\nQuestion: {prompt}"}
                ],
            }
        ],
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
    body = json.loads(event.get("body") or "{}")
    prompt = body.get("prompt", "").strip()
    session_id = body.get("session_id") or str(uuid.uuid4())

    if not prompt:
        return {"statusCode": 400, "body": json.dumps({"error": "prompt is required"})}

    if KB_MODE == "managed":
        answer, guardrail_action, sources = _query_managed_kb(prompt)
    else:
        answer, guardrail_action, sources = _query_vector_kb(prompt)

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

    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(
            {
                "session_id": session_id,
                "answer": answer,
                "guardrail_action": guardrail_action,
                "sources": sources,
            }
        ),
    }
