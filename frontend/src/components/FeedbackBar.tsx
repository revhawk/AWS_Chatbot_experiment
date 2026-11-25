import { useState } from "react";

interface FeedbackBarProps {
  messageId: string;
  submitted?: "up" | "down";
  onSubmit: (messageId: string, rating: "up" | "down", comment: string) => Promise<void>;
}

/** Control C11: Answer rating & optional reviewer feedback widget. */
export function FeedbackBar({ messageId, submitted, onSubmit }: FeedbackBarProps) {
  const [comment, setComment] = useState("");
  const [showComment, setShowComment] = useState(false);
  const [busy, setBusy] = useState(false);

  if (submitted) {
    return (
      <div className="feedback-done">
        Feedback recorded ({submitted === "up" ? "Helpful" : "Needs review"}).
      </div>
    );
  }

  async function send(rating: "up" | "down") {
    setBusy(true);
    try {
      await onSubmit(messageId, rating, comment);
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="feedback-bar">
      <span>Rate this answer:</span>
      <button type="button" disabled={busy} onClick={() => send("up")} aria-label="Helpful">
        Helpful
      </button>
      <button type="button" disabled={busy} onClick={() => send("down")} aria-label="Needs review">
        Needs review
      </button>
      <button type="button" className="link-btn" onClick={() => setShowComment((v) => !v)}>
        {showComment ? "Hide note" : "Add note"}
      </button>
      {showComment && (
        <input
          type="text"
          className="feedback-input"
          value={comment}
          onChange={(e) => setComment(e.target.value)}
          maxLength={1000}
          placeholder="Optional feedback for knowledge reviewers..."
        />
      )}
    </div>
  );
}
