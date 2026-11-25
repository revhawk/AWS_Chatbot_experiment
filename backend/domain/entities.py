"""Layer 1: Pure domain entities and validation rules (Controls C1, C3, C11)."""

from dataclasses import dataclass, field
import re
import uuid

from backend.domain.errors import ValidationError

MAX_PROMPT_LENGTH = 2000
MAX_COMMENT_LENGTH = 1000
MAX_SESSION_ID_LENGTH = 128
_SESSION_ID_RE = re.compile(r"^[a-zA-Z0-9_-]{1,128}$")
_ALLOWED_CHAT_KEYS = frozenset({"prompt", "session_id"})
_ALLOWED_FEEDBACK_KEYS = frozenset({"session_id", "message_id", "rating", "comment"})
_ALLOWED_RATINGS = frozenset({"up", "down"})


@dataclass(frozen=True)
class VerifiedUser:
    """Identity derived strictly from verified Entra ID / OIDC JWT claims (Control C1)."""

    user_id: str
    display_name: str = ""
    roles: tuple[str, ...] = ()

    def __post_init__(self):
        if not self.user_id or not self.user_id.strip():
            raise ValueError("VerifiedUser.user_id must be non-empty")


@dataclass(frozen=True)
class Citation:
    """A grounded source reference returned with an answer (Control C6)."""

    uri: str
    title: str = ""


@dataclass(frozen=True)
class ChatRequest:
    """Validated user chat request (Control C3)."""

    prompt: str
    session_id: str

    @classmethod
    def from_payload(cls, payload: object) -> "ChatRequest":
        if not isinstance(payload, dict):
            raise ValidationError("Request body must be a JSON object")

        unknown_keys = set(payload.keys()) - _ALLOWED_CHAT_KEYS
        if unknown_keys:
            raise ValidationError(f"Unexpected request field(s): {', '.join(sorted(unknown_keys))}")

        raw_prompt = payload.get("prompt")
        if not isinstance(raw_prompt, str):
            raise ValidationError("prompt must be a non-empty string")
        prompt = raw_prompt.strip()
        if not prompt:
            raise ValidationError("prompt is required")
        if len(prompt) > MAX_PROMPT_LENGTH:
            raise ValidationError(f"prompt exceeds maximum length of {MAX_PROMPT_LENGTH} characters")

        raw_session = payload.get("session_id")
        if raw_session is None or raw_session == "":
            session_id = str(uuid.uuid4())
        elif isinstance(raw_session, str) and _SESSION_ID_RE.match(raw_session):
            session_id = raw_session
        else:
            raise ValidationError(
                f"session_id must be 1-{MAX_SESSION_ID_LENGTH} alphanumeric, hyphen, or underscore characters"
            )

        return cls(prompt=prompt, session_id=session_id)


@dataclass(frozen=True)
class ChatResponse:
    """Grounded chat response with guardrail status and citations (Controls C4, C6, C7)."""

    session_id: str
    answer: str
    guardrail_action: str
    citations: tuple[Citation, ...] = field(default_factory=tuple)
    grounded: bool = True

    def to_dict(self) -> dict:
        return {
            "session_id": self.session_id,
            "answer": self.answer,
            "guardrail_action": self.guardrail_action,
            "sources": [c.uri for c in self.citations],
            "grounded": self.grounded,
        }


@dataclass(frozen=True)
class FeedbackEntry:
    """User answer rating & comment scoped to verified user_id (Control C11)."""

    user_id: str
    session_id: str
    message_id: str
    rating: str
    comment: str = ""

    @classmethod
    def from_payload(cls, user: VerifiedUser, payload: object) -> "FeedbackEntry":
        if not isinstance(payload, dict):
            raise ValidationError("Request body must be a JSON object")

        unknown_keys = set(payload.keys()) - _ALLOWED_FEEDBACK_KEYS
        if unknown_keys:
            raise ValidationError(f"Unexpected feedback field(s): {', '.join(sorted(unknown_keys))}")

        session_id = payload.get("session_id")
        if not isinstance(session_id, str) or not _SESSION_ID_RE.match(session_id):
            raise ValidationError("Valid session_id is required")

        message_id = payload.get("message_id")
        if not isinstance(message_id, str) or not _SESSION_ID_RE.match(message_id):
            raise ValidationError("Valid message_id is required")

        rating = payload.get("rating")
        if not isinstance(rating, str) or rating.lower() not in _ALLOWED_RATINGS:
            raise ValidationError("rating must be 'up' or 'down'")

        raw_comment = payload.get("comment", "")
        if not isinstance(raw_comment, str):
            raise ValidationError("comment must be a string")
        comment = raw_comment.strip()
        if len(comment) > MAX_COMMENT_LENGTH:
            raise ValidationError(f"comment exceeds maximum length of {MAX_COMMENT_LENGTH} characters")

        return cls(
            user_id=user.user_id,
            session_id=session_id,
            message_id=message_id,
            rating=rating.lower(),
            comment=comment,
        )
