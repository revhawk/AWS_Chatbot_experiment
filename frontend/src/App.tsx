import { useMemo, useState, type FormEvent } from "react";
import { ApiClientError, MAX_PROMPT_LENGTH, RagApiClient } from "./api/ragApi.js";
import { AiUsageNotice } from "./components/AiUsageNotice.tsx";
import { ChatMessage } from "./components/ChatMessage.tsx";
import { LoginPanel } from "./components/LoginPanel.tsx";
import type { AuthMode, AuthSession, UiMessage } from "./types.ts";

const AUTH_CONFIG = {
  mode: ((import.meta.env.VITE_AUTH_MODE as AuthMode) || "mock_oidc"),
  tenantId: import.meta.env.VITE_ENTRA_TENANT_ID || "",
  clientId: import.meta.env.VITE_ENTRA_CLIENT_ID || "",
  scope: import.meta.env.VITE_ENTRA_SCOPE || "api://bedrock-rag-assistant/chat.read",
  redirectUri: import.meta.env.VITE_REDIRECT_URI || window.location.origin,
};

export function App() {
  const api = useMemo(
    () => new RagApiClient(import.meta.env.VITE_API_BASE_URL || "/api"),
    [],
  );
  const [session, setSession] = useState<AuthSession | null>(null);
  const [sessionId, setSessionId] = useState<string | undefined>(undefined);
  const [messages, setMessages] = useState<UiMessage[]>([]);
  const [prompt, setPrompt] = useState("");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  if (!session) {
    return (
      <main className="page-shell">
        <AiUsageNotice />
        <LoginPanel authConfig={AUTH_CONFIG} onSignedIn={setSession} />
      </main>
    );
  }

  async function handleAsk(e: FormEvent) {
    e.preventDefault();
    if (!session || loading) return;
    setError(null);
    const cleaned = prompt.trim();
    if (!cleaned) return;

    const userMsg: UiMessage = { id: crypto.randomUUID(), role: "user", text: cleaned };
    setMessages((prev) => [...prev, userMsg]);
    setPrompt("");
    setLoading(true);

    try {
      const resp = await api.askQuestion(session.accessToken, cleaned, sessionId);
      setSessionId(resp.session_id);
      const botMsg: UiMessage = {
        id: crypto.randomUUID(),
        role: "assistant",
        text: resp.answer,
        guardrailAction: resp.guardrail_action,
        sources: resp.sources,
        grounded: resp.grounded,
      };
      setMessages((prev) => [...prev, botMsg]);
    } catch (err) {
      if (err instanceof ApiClientError && err.statusCode === 401) {
        setSession(null);
      }
      setError(err instanceof Error ? err.message : "Failed to reach AI API.");
    } finally {
      setLoading(false);
    }
  }

  async function handleFeedback(messageId: string, rating: "up" | "down", comment: string) {
    if (!session || !sessionId) return;
    try {
      await api.submitFeedback(session.accessToken, sessionId, messageId, rating, comment);
      setMessages((prev) =>
        prev.map((m) => (m.id === messageId ? { ...m, feedbackSubmitted: rating } : m)),
      );
    } catch (err) {
      setError(err instanceof Error ? err.message : "Unable to submit feedback.");
    }
  }

  return (
    <main className="page-shell">
      <header className="top-bar">
        <div>
          <h1>AI Knowledge Assistant</h1>
          <span className="subtitle">Signed in as {session.displayName}</span>
        </div>
        <button type="button" onClick={() => setSession(null)}>
          Sign out
        </button>
      </header>

      <AiUsageNotice />

      <section className="chat-log" aria-live="polite">
        {messages.length === 0 ? (
          <p className="empty-state">Ask a question grounded in your approved knowledge base.</p>
        ) : (
          messages.map((m) => <ChatMessage key={m.id} message={m} onFeedback={handleFeedback} />)
        )}
      </section>

      {error && <p className="error-text">{error}</p>}

      <form className="composer" onSubmit={handleAsk}>
        <input
          type="text"
          value={prompt}
          maxLength={MAX_PROMPT_LENGTH}
          onChange={(e) => setPrompt(e.target.value)}
          placeholder="Ask a question..."
          disabled={loading}
        />
        <button type="submit" className="primary-btn" disabled={loading || !prompt.trim()}>
          {loading ? "Thinking..." : "Send"}
        </button>
      </form>
    </main>
  );
}
