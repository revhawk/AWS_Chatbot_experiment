"""Use Case: Authenticate user, validate input, invoke retrieval-only AI runtime, log audit."""

from backend.domain.entities import ChatRequest, ChatResponse
from backend.use_cases.ports import AgentRuntimePort, AuditLoggerPort, TokenVerifierPort


class AskQuestionUseCase:
    def __init__(
        self,
        token_verifier: TokenVerifierPort,
        agent_runtime: AgentRuntimePort,
        audit_logger: AuditLoggerPort,
    ):
        self._token_verifier = token_verifier
        self._agent_runtime = agent_runtime
        self._audit_logger = audit_logger

    def execute(self, authorization_header: str | None, payload: object) -> ChatResponse:
        # C1: Verify JWT first; user_id comes exclusively from verified token claims.
        user = self._token_verifier.verify_bearer_token(authorization_header)

        # C3: Enforce strict request schema and length limits before invoking AI runtime.
        request = ChatRequest.from_payload(payload)

        # C5/C6/C8: Invoke retrieval-only AgentCore Runtime scoped to verified user + session.
        response = self._agent_runtime.invoke(user=user, request=request)

        # C10/C12: Record audit turn without failing the user response if audit storage has a blip.
        try:
            self._audit_logger.record_chat_turn(user=user, request=request, response=response)
        except Exception:
            pass

        return response
