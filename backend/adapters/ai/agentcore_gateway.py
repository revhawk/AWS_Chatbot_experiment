"""Layer 3 AI Adapter: Invokes AgentCore Runtime via VPC Interface Endpoint (Controls C5, C6, C8)."""

import json

from backend.domain.entities import ChatRequest, ChatResponse, Citation, VerifiedUser
from backend.domain.errors import UpstreamError, UpstreamThrottledError


class AgentCoreRuntimeGateway:
    """Calls bedrock-agentcore InvokeAgentRuntime over the AgentCore Interface VPCE."""

    def __init__(self, agentcore_client, runtime_arn: str):
        self._client = agentcore_client
        self._runtime_arn = runtime_arn

    def invoke(self, user: VerifiedUser, request: ChatRequest) -> ChatResponse:
        # C8: Scope runtime session strictly to verified user_id + session_id.
        scoped_session_id = f"{user.user_id}:{request.session_id}"
        payload = json.dumps(
            {
                "prompt": request.prompt,
                "user_id": user.user_id,
                "session_id": request.session_id,
            }
        ).encode("utf-8")

        try:
            resp = self._client.invoke_agent_runtime(
                agentRuntimeArn=self._runtime_arn,
                runtimeSessionId=scoped_session_id,
                payload=payload,
            )
        except Exception as exc:
            code = getattr(exc, "response", {}).get("Error", {}).get("Code", "")
            if code == "ThrottlingException":
                raise UpstreamThrottledError("AI runtime throttled request") from exc
            raise UpstreamError(f"AgentCore Runtime call failed: {code or type(exc).__name__}") from exc

        raw_body = resp.get("response", b"{}")
        if hasattr(raw_body, "read"):
            raw_body = raw_body.read()
        if isinstance(raw_body, bytes):
            raw_body = raw_body.decode("utf-8")

        data = json.loads(raw_body) if isinstance(raw_body, str) else raw_body
        citations = tuple(
            Citation(uri=s["uri"], title=s.get("title", ""))
            if isinstance(s, dict)
            else Citation(uri=str(s))
            for s in data.get("sources", [])
        )
        return ChatResponse(
            session_id=request.session_id,
            answer=str(data.get("answer", "")),
            guardrail_action=str(data.get("guardrail_action", "NONE")),
            citations=citations,
            grounded=bool(data.get("grounded", True)),
        )
