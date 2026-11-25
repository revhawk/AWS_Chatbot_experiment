export type AuthMode = "mock_oidc" | "entra_id";

export interface AuthSession {
  accessToken: string;
  displayName: string;
  authMode: AuthMode;
}

export interface ChatApiResponse {
  session_id: string;
  answer: string;
  guardrail_action: "NONE" | "INTERVENED" | string;
  sources: string[];
  grounded: boolean;
}

export interface FeedbackApiResponse {
  status: string;
  session_id: string;
  message_id: string;
  rating: "up" | "down";
}

export interface UiMessage {
  id: string;
  role: "user" | "assistant";
  text: string;
  guardrailAction?: string;
  sources?: string[];
  grounded?: boolean;
  feedbackSubmitted?: "up" | "down";
}
