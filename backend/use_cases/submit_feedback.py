"""Use Case: Authenticate user, validate feedback payload, persist rating (Control C11)."""

from backend.domain.entities import FeedbackEntry
from backend.use_cases.ports import FeedbackStorePort, TokenVerifierPort


class SubmitFeedbackUseCase:
    def __init__(
        self,
        token_verifier: TokenVerifierPort,
        feedback_store: FeedbackStorePort,
    ):
        self._token_verifier = token_verifier
        self._feedback_store = feedback_store

    def execute(self, authorization_header: str | None, payload: object) -> FeedbackEntry:
        # C1: Verify JWT; user_id is strictly derived from verified token claims.
        user = self._token_verifier.verify_bearer_token(authorization_header)

        # C3/C11: Validate rating, message/session IDs, and comment length.
        entry = FeedbackEntry.from_payload(user=user, payload=payload)
        self._feedback_store.save_feedback(entry)
        return entry
