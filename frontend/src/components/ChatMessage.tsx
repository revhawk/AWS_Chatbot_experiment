import type { UiMessage } from "../types.ts";
import { FeedbackBar } from "./FeedbackBar.tsx";

interface ChatMessageProps {
  message: UiMessage;
  onFeedback: (messageId: string, rating: "up" | "down", comment: string) => Promise<void>;
}

export function ChatMessage({ message, onFeedback }: ChatMessageProps) {
  const isAssistant = message.role === "assistant";
  const intervened = message.guardrailAction === "INTERVENED";

  return (
    <article className={`msg msg-${message.role}`}>
      <header className="msg-header">
        <strong>{isAssistant ? "AI Assistant" : "You"}</strong>
        {isAssistant && (
          <span className={`pill ${intervened ? "pill-warn" : "pill-ok"}`}>
            Guardrail: {message.guardrailAction ?? "NONE"}
          </span>
        )}
        {isAssistant && message.grounded !== undefined && (
          <span className={`pill ${message.grounded ? "pill-ok" : "pill-muted"}`}>
            {message.grounded ? "Grounded" : "Ungrounded"}
          </span>
        )}
      </header>

      <p className="msg-text">{message.text}</p>

      {isAssistant && message.sources && message.sources.length > 0 && (
        <div className="citations">
          <strong>Sources:</strong>
          <ul>
            {message.sources.map((uri) => (
              <li key={uri}>
                {uri.startsWith("https://") ? (
                  <a href={uri} target="_blank" rel="noreferrer">
                    {uri}
                  </a>
                ) : (
                  <code>{uri}</code>
                )}
              </li>
            ))}
          </ul>
        </div>
      )}

      {isAssistant && (
        <FeedbackBar
          messageId={message.id}
          submitted={message.feedbackSubmitted}
          onSubmit={onFeedback}
        />
      )}
    </article>
  );
}
