/**
 * API client for Private REST API Gateway (/api/chat and /api/feedback).
 * Control C1: Always sends Authorization: Bearer <token>; never sends user_id in request body.
 * Control C3: Enforces client-side prompt/comment length limits matching backend domain rules.
 */

export const MAX_PROMPT_LENGTH = 2000;
export const MAX_COMMENT_LENGTH = 1000;

export class ApiClientError extends Error {
  constructor(statusCode, message) {
    super(message);
    this.name = "ApiClientError";
    this.statusCode = statusCode;
  }
}

export class RagApiClient {
  constructor(baseUrl = "/api", fetchImpl = fetch) {
    this.baseUrl = baseUrl.replace(/\/+$/, "");
    this.fetchImpl = fetchImpl;
  }

  async postJson(path, accessToken, body) {
    if (!accessToken || !accessToken.trim()) {
      throw new ApiClientError(401, "Sign in required before calling the API.");
    }

    const resp = await this.fetchImpl(`${this.baseUrl}${path}`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${accessToken.trim()}`,
      },
      body: JSON.stringify(body),
    });

    const data = await resp.json().catch(() => ({}));
    if (!resp.ok) {
      const msg =
        typeof data.error === "string"
          ? data.error
          : resp.status === 401
            ? "Session expired or invalid token. Please sign in again."
            : `Request failed with HTTP ${resp.status}`;
      throw new ApiClientError(resp.status, msg);
    }
    return data;
  }

  async askQuestion(accessToken, prompt, sessionId) {
    const cleaned = String(prompt || "").trim();
    if (!cleaned) {
      throw new ApiClientError(400, "Please enter a question.");
    }
    if (cleaned.length > MAX_PROMPT_LENGTH) {
      throw new ApiClientError(400, `Question exceeds ${MAX_PROMPT_LENGTH} characters.`);
    }

    const payload = { prompt: cleaned };
    if (sessionId) {
      payload.session_id = sessionId;
    }
    return this.postJson("/chat", accessToken, payload);
  }

  async submitFeedback(accessToken, sessionId, messageId, rating, comment = "") {
    const cleanedComment = String(comment || "").trim();
    if (cleanedComment.length > MAX_COMMENT_LENGTH) {
      throw new ApiClientError(400, `Feedback comment exceeds ${MAX_COMMENT_LENGTH} characters.`);
    }

    return this.postJson("/feedback", accessToken, {
      session_id: sessionId,
      message_id: messageId,
      rating,
      comment: cleanedComment,
    });
  }
}
