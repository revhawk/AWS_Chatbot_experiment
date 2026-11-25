/**
 * Offline unit & contract tests for frontend authClient and RagApiClient
 * Run with Node 22+: node --test frontend/tests/contract.test.mjs
 */

import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { buildEntraAuthorizeUrl, createMockSession } from "../src/auth/authClient.js";
import { ApiClientError, MAX_COMMENT_LENGTH, MAX_PROMPT_LENGTH, RagApiClient } from "../src/api/ragApi.js";

describe("authClient (Control C1)", () => {
  it("builds a valid Microsoft Entra ID OIDC PKCE authorize URL", () => {
    const url = buildEntraAuthorizeUrl(
      {
        mode: "entra_id",
        tenantId: "tenant-123",
        clientId: "client-456",
        scope: "api://bedrock-rag-assistant/chat.read",
        redirectUri: "https://app.internal/",
      },
      "state-xyz",
      "challenge-abc",
    );
    const parsed = new URL(url);
    assert.equal(parsed.origin, "https://login.microsoftonline.com");
    assert.equal(parsed.pathname, "/tenant-123/oauth2/v2.0/authorize");
    assert.equal(parsed.searchParams.get("client_id"), "client-456");
    assert.equal(parsed.searchParams.get("code_challenge_method"), "S256");
    assert.equal(parsed.searchParams.get("response_type"), "code");
  });

  it("rejects empty mock token and creates valid mock session", () => {
    assert.throws(() => createMockSession("   "), /Bearer JWT/);
    const sess = createMockSession("eyJ.mock.jwt", "Alice");
    assert.equal(sess.accessToken, "eyJ.mock.jwt");
    assert.equal(sess.displayName, "Alice");
    assert.equal(sess.authMode, "mock_oidc");
  });
});

describe("RagApiClient contract (Controls C1, C3, C11)", () => {
  it("sends Bearer JWT, never sends user_id in body, and returns grounded response", async () => {
    const calls = [];
    const fakeFetch = async (url, init) => {
      calls.push({ url, init });
      return {
        ok: true,
        status: 200,
        json: async () => ({
          session_id: "sess-1",
          answer: "Grounded answer.",
          guardrail_action: "NONE",
          sources: ["https://tenant.sharepoint.com/doc.pdf"],
          grounded: true,
        }),
      };
    };

    const client = new RagApiClient("/api", fakeFetch);
    const resp = await client.askQuestion("jwt-token-123", "  What is RAG?  ", "sess-1");
    assert.equal(resp.answer, "Grounded answer.");
    assert.equal(resp.grounded, true);
    assert.equal(calls.length, 1);
    assert.equal(calls[0].url, "/api/chat");
    assert.equal(calls[0].init.headers.Authorization, "Bearer jwt-token-123");

    const sentBody = JSON.parse(calls[0].init.body);
    assert.deepEqual(sentBody, { prompt: "What is RAG?", session_id: "sess-1" });
    assert.equal("user_id" in sentBody, false);
  });

  it("enforces client-side C3 validation and maps HTTP 401 cleanly", async () => {
    const unauthFetch = async () => ({
      ok: false,
      status: 401,
      json: async () => ({ error: "Token has expired" }),
    });
    const client = new RagApiClient("/api", unauthFetch);

    await assert.rejects(
      () => client.askQuestion("", "hello"),
      (err) => err instanceof ApiClientError && err.statusCode === 401,
    );
    await assert.rejects(
      () => client.askQuestion("tok", "x".repeat(MAX_PROMPT_LENGTH + 1)),
      (err) => err instanceof ApiClientError && err.statusCode === 400,
    );
    await assert.rejects(
      () => client.askQuestion("expired-tok", "hello"),
      (err) => err instanceof ApiClientError && err.statusCode === 401 && /expired/.test(err.message),
    );
  });

  it("submits feedback ratings to /api/feedback (Control C11)", async () => {
    const calls = [];
    const fakeFetch = async (url, init) => {
      calls.push({ url, init });
      return {
        ok: true,
        status: 201,
        json: async () => ({ status: "recorded", session_id: "s1", message_id: "m1", rating: "up" }),
      };
    };
    const client = new RagApiClient("/api", fakeFetch);
    const res = await client.submitFeedback("tok-1", "s1", "m1", "up", "Clear citations");
    assert.equal(res.status, "recorded");
    assert.equal(calls[0].url, "/api/feedback");
    assert.deepEqual(JSON.parse(calls[0].init.body), {
      session_id: "s1",
      message_id: "m1",
      rating: "up",
      comment: "Clear citations",
    });

    await assert.rejects(
      () => client.submitFeedback("tok-1", "s1", "m1", "down", "a".repeat(MAX_COMMENT_LENGTH + 1)),
      (err) => err instanceof ApiClientError && err.statusCode === 400,
    );
  });
});
