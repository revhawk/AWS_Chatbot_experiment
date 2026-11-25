/** Control C11: Persistent AI usage notice shown to authenticated users. */

export function AiUsageNotice() {
  return (
    <aside className="ai-notice" role="note" aria-label="AI Usage Notice">
      <strong>AI Usage Notice:</strong> Responses are AI-generated from approved knowledge sources only
      (retrieval-only, no automated actions) and protected by Bedrock Guardrails. Always verify critical
      engineering or policy decisions against the cited source documents.
    </aside>
  );
}
