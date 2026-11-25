"""AWS Bedrock adapters for AgentCore Runtime (VPC Mode via Bedrock Interface VPCEs)."""

from agentcore_runtime.use_cases import GuardrailVerdict, RetrievedChunk


def extract_location_uri(location: object) -> str:
    if not isinstance(location, dict):
        return ""
    return (
        location.get("sharePointLocation", {}).get("url")
        or location.get("s3Location", {}).get("uri")
        or location.get("webLocation", {}).get("url")
        or ""
    )


class BedrockGuardrailGateway:
    """Calls bedrock-runtime.apply_guardrail for C4 input checks."""

    def __init__(self, bedrock_runtime_client, guardrail_id: str, guardrail_version: str):
        self._client = bedrock_runtime_client
        self._guardrail_id = guardrail_id
        self._guardrail_version = guardrail_version

    def check_input(self, text: str) -> GuardrailVerdict:
        resp = self._client.apply_guardrail(
            guardrailIdentifier=self._guardrail_id,
            guardrailVersion=self._guardrail_version,
            source="INPUT",
            content=[{"text": {"text": text}}],
        )
        intervened = resp.get("action") == "GUARDRAIL_INTERVENED"
        outputs = resp.get("outputs") or []
        message = outputs[0].get("text", "") if outputs else ""
        return GuardrailVerdict(intervened=intervened, message=message)


class BedrockManagedKbGateway:
    """Calls bedrock-agent-runtime.retrieve over Bedrock Interface VPCE."""

    def __init__(self, bedrock_agent_client, kb_id: str, num_results: int = 5):
        self._client = bedrock_agent_client
        self._kb_id = kb_id
        self._num_results = num_results

    def retrieve(self, query: str, user_id: str) -> list[RetrievedChunk]:
        resp = self._client.retrieve(
            knowledgeBaseId=self._kb_id,
            retrievalQuery={"text": query},
            retrievalConfiguration={
                "managedSearchConfiguration": {"numberOfResults": self._num_results}
            },
        )
        chunks = []
        for item in resp.get("retrievalResults", []):
            text = item.get("content", {}).get("text", "")
            uri = extract_location_uri(item.get("location"))
            if text:
                chunks.append(RetrievedChunk(text=text, source_uri=uri))
        return chunks


class BedrockConverseGateway:
    """Calls bedrock-runtime.converse with output guardrails & contextual grounding (C6, C7)."""

    SYSTEM_PROMPT = (
        "You are a retrieval-only AI assistant. Answer strictly using the provided "
        "approved knowledge context and prior conversation history. Do not invent facts. "
        "If the context does not contain the answer, state that you do not have enough information."
    )

    def __init__(self, bedrock_runtime_client, model_arn: str, guardrail_id: str, guardrail_version: str):
        self._client = bedrock_runtime_client
        self._model_arn = model_arn
        self._guardrail_id = guardrail_id
        self._guardrail_version = guardrail_version

    def generate(self, prompt: str, chunks: list[RetrievedChunk], history: list[dict]) -> tuple[str, bool]:
        context_block = "\n\n---\n\n".join(c.text for c in chunks) if chunks else "No relevant documents found."
        messages = []
        for turn in history:
            if turn.get("prompt"):
                messages.append({"role": "user", "content": [{"text": turn["prompt"]}]})
            if turn.get("answer"):
                messages.append({"role": "assistant", "content": [{"text": turn["answer"]}]})

        # Pass grounding source block for Bedrock Contextual Grounding check (C7).
        messages.append(
            {
                "role": "user",
                "content": [
                    {
                        "guardContent": {
                            "text": {"text": context_block, "qualifiers": ["grounding_source"]}
                        }
                    },
                    {
                        "guardContent": {
                            "text": {"text": prompt, "qualifiers": ["query"]}
                        }
                    },
                ],
            }
        )

        resp = self._client.converse(
            modelId=self._model_arn,
            system=[{"text": self.SYSTEM_PROMPT}],
            messages=messages,
            guardrailConfig={
                "guardrailIdentifier": self._guardrail_id,
                "guardrailVersion": self._guardrail_version,
            },
        )
        blocks = resp.get("output", {}).get("message", {}).get("content", [])
        answer = "".join(b.get("text", "") for b in blocks)
        intervened = resp.get("stopReason") == "guardrail_intervened"
        return answer, intervened
