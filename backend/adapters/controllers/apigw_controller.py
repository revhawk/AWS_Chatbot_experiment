"""Layer 3 Controller Adapter: Private API Gateway proxy -> Clean Architecture Use Cases."""

import json

from backend.domain.errors import (
    UnauthorizedError,
    UpstreamError,
    UpstreamThrottledError,
    ValidationError,
)
from backend.use_cases.ask_question import AskQuestionUseCase
from backend.use_cases.submit_feedback import SubmitFeedbackUseCase


def _json_response(status_code: int, payload: dict) -> dict:
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json",
            "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff",
        },
        "body": json.dumps(payload),
    }


def _get_header(headers: dict | None, name: str) -> str | None:
    if not isinstance(headers, dict):
        return None
    target = name.lower()
    for k, v in headers.items():
        if isinstance(k, str) and k.lower() == target:
            return v
    return None


class ApiGatewayController:
    def __init__(
        self,
        ask_use_case: AskQuestionUseCase,
        feedback_use_case: SubmitFeedbackUseCase,
    ):
        self._ask = ask_use_case
        self._feedback = feedback_use_case

    def handle(self, event: dict) -> dict:
        path = str(event.get("path") or "/api/chat").rstrip("/")
        auth_header = _get_header(event.get("headers"), "Authorization")

        try:
            body = json.loads(event.get("body") or "{}")
        except json.JSONDecodeError:
            return _json_response(400, {"error": "Invalid JSON in request body"})

        try:
            if path.endswith("/chat"):
                response = self._ask.execute(authorization_header=auth_header, payload=body)
                return _json_response(200, response.to_dict())
            if path.endswith("/feedback"):
                entry = self._feedback.execute(authorization_header=auth_header, payload=body)
                return _json_response(
                    201,
                    {
                        "status": "recorded",
                        "session_id": entry.session_id,
                        "message_id": entry.message_id,
                        "rating": entry.rating,
                    },
                )
            return _json_response(404, {"error": f"Unknown route: {path}"})
        except UnauthorizedError as exc:
            return _json_response(401, {"error": str(exc)})
        except ValidationError as exc:
            return _json_response(400, {"error": str(exc)})
        except UpstreamThrottledError as exc:
            return _json_response(429, {"error": str(exc)})
        except UpstreamError as exc:
            return _json_response(502, {"error": str(exc)})
