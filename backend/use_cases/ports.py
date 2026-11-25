"""Abstract ports (interfaces) implemented by Layer 3 adapters."""

from typing import Protocol

from backend.domain.entities import ChatRequest, ChatResponse, FeedbackEntry, VerifiedUser


class TokenVerifierPort(Protocol):
    """Validates Bearer JWT tokens and returns a VerifiedUser (Control C1)."""

    def verify_bearer_token(self, authorization_header: str | None) -> VerifiedUser: ...


class AgentRuntimePort(Protocol):
    """Invokes the retrieval-only AI runtime (AgentCore VPC Mode — Controls C5, C6, C8)."""

    def invoke(self, user: VerifiedUser, request: ChatRequest) -> ChatResponse: ...


class FeedbackStorePort(Protocol):
    """Persists user answer ratings and comments (Control C11)."""

    def save_feedback(self, entry: FeedbackEntry) -> None: ...


class AuditLoggerPort(Protocol):
    """Records PII-redacted audit events (Controls C10, C12)."""

    def record_chat_turn(
        self,
        user: VerifiedUser,
        request: ChatRequest,
        response: ChatResponse,
    ) -> None: ...
