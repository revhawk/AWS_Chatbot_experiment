"""Layer 3 Logging Adapter: Structured JSON logger with PII redaction (Control C12)."""

import json
import logging
import re

_PII_PATTERNS = (
    (re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"), "[REDACTED_EMAIL]"),
    (re.compile(r"\b(?:07\d{9}|\+44\s?7\d{3}\s?\d{6}|\+?\d{1,3}[-.\s]?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4})\b"), "[REDACTED_PHONE]"),
    (re.compile(r"\bAKIA[0-9A-Z]{16}\b"), "[REDACTED_AWS_KEY]"),
    (re.compile(r"\b[A-Z]{2}\s?\d{2}\s?\d{2}\s?\d{2}\s?[A-D]\b", re.IGNORECASE), "[REDACTED_NI]"),
    (re.compile(r"Bearer\s+[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]+", re.IGNORECASE), "Bearer [REDACTED_JWT]"),
)


def redact_pii(text: str) -> str:
    """Scrub common PII and secrets before writing to CloudWatch Logs (Control C12)."""
    if not isinstance(text, str):
        return str(text)
    cleaned = text
    for pattern, replacement in _PII_PATTERNS:
        cleaned = pattern.sub(replacement, cleaned)
    return cleaned


class RedactingLogger:
    def __init__(self, logger: logging.Logger | None = None):
        self._logger = logger or logging.getLogger("rag_assistant")

    def info(self, event: str, **fields) -> None:
        safe_fields = {k: redact_pii(v) if isinstance(v, str) else v for k, v in fields.items()}
        self._logger.info(json.dumps({"event": event, **safe_fields}))

    def error(self, event: str, **fields) -> None:
        safe_fields = {k: redact_pii(v) if isinstance(v, str) else v for k, v in fields.items()}
        self._logger.error(json.dumps({"event": event, **safe_fields}))
