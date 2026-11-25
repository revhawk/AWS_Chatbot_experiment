"""Domain-level error hierarchy mapped to HTTP status codes at the controller boundary."""


class DomainError(Exception):
    """Base error for application/domain failures."""


class UnauthorizedError(DomainError):
    """Raised when JWT authentication fails (HTTP 401 — Control C1)."""


class ValidationError(DomainError):
    """Raised when request schema or input limits fail (HTTP 400 — Control C3)."""


class UpstreamThrottledError(DomainError):
    """Raised when downstream AI runtime throttles requests (HTTP 429)."""


class UpstreamError(DomainError):
    """Raised when downstream AWS/AI services fail (HTTP 502)."""
