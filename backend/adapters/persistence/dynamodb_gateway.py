"""Layer 3 Persistence Adapter: DynamoDB audit & feedback store via Gateway VPCE (Controls C8, C11, C12)."""

from datetime import datetime, timezone

from backend.adapters.logging.redacting_logger import redact_pii
from backend.domain.entities import ChatRequest, ChatResponse, FeedbackEntry, VerifiedUser


class DynamoDbGateway:
    """Stores PII-safe audit records and user answer feedback in DynamoDB."""

    def __init__(self, table):
        self._table = table

    def record_chat_turn(
        self,
        user: VerifiedUser,
        request: ChatRequest,
        response: ChatResponse,
    ) -> None:
        self._table.put_item(
            Item={
                "session_id": f"{user.user_id}#{request.session_id}",
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "record_type": "CHAT_TURN",
                "user_id": user.user_id,
                "prompt_redacted": redact_pii(request.prompt),
                "answer_redacted": redact_pii(response.answer),
                "guardrail_action": response.guardrail_action,
                "grounded": response.grounded,
                "sources": [c.uri for c in response.citations],
            }
        )

    def save_feedback(self, entry: FeedbackEntry) -> None:
        self._table.put_item(
            Item={
                "session_id": f"{entry.user_id}#{entry.session_id}",
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "record_type": "FEEDBACK",
                "user_id": entry.user_id,
                "message_id": entry.message_id,
                "rating": entry.rating,
                "comment": redact_pii(entry.comment),
            }
        )
