import json
import os
import uuid
from datetime import datetime, timezone
import boto3

bedrock_agent = boto3.client("bedrock-agent-runtime", region_name=os.environ["AWS_REGION"])
dynamodb = boto3.resource("dynamodb", region_name=os.environ["AWS_REGION"])
table = dynamodb.Table(os.environ["TABLE_NAME"])

KB_ID = os.environ["KB_ID"]
MODEL_ARN = os.environ["MODEL_ARN"]
GUARDRAIL_ID = os.environ["GUARDRAIL_ID"]
GUARDRAIL_VERSION = os.environ["GUARDRAIL_VERSION"]


def lambda_handler(event, context):
    body = json.loads(event.get("body") or "{}")
    prompt = body.get("prompt", "").strip()
    session_id = body.get("session_id") or str(uuid.uuid4())

    if not prompt:
        return {"statusCode": 400, "body": json.dumps({"error": "prompt is required"})}

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
