import { useState, type FormEvent } from "react";
import { buildEntraAuthorizeUrl, createMockSession } from "../auth/authClient.js";
import type { AuthMode, AuthSession } from "../types.ts";

interface AuthConfig {
  mode: AuthMode;
  tenantId: string;
  clientId: string;
  scope: string;
  redirectUri: string;
}

interface LoginPanelProps {
  authConfig: AuthConfig;
  onSignedIn: (session: AuthSession) => void;
}

export function LoginPanel({ authConfig, onSignedIn }: LoginPanelProps) {
  const [mockToken, setMockToken] = useState("");
  const [displayName, setDisplayName] = useState("Authenticated User");
  const [error, setError] = useState<string | null>(null);

  function handleEntraLogin() {
    try {
      const state = crypto.randomUUID();
      const challenge = crypto.randomUUID().replace(/-/g, "");
      const url = buildEntraAuthorizeUrl(authConfig, state, challenge);
      window.location.assign(url);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Unable to start Entra ID sign-in.");
    }
  }

  function handleMockSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    try {
      onSignedIn(createMockSession(mockToken, displayName));
    } catch (err) {
      setError(err instanceof Error ? err.message : "Invalid mock token.");
    }
  }

  return (
    <section className="login-card">
      <h1>AI Knowledge Assistant</h1>
      <p className="subtitle">
        Private access via managed device &amp; access policy. Sign in to obtain a verified session token.
      </p>

      {authConfig.mode === "entra_id" ? (
        <button type="button" className="primary-btn" onClick={handleEntraLogin}>
          Sign in with Microsoft Entra ID
        </button>
      ) : (
        <form onSubmit={handleMockSubmit} className="login-form">
          <p className="badge">Sandbox Mode: Mock Entra ID (RS256 Bearer JWT)</p>
          <label>
            Display Name
            <input
              type="text"
              value={displayName}
              onChange={(e) => setDisplayName(e.target.value)}
              placeholder="Authenticated User"
            />
          </label>
          <label>
            Signed RS256 Bearer Token
            <textarea
              rows={3}
              value={mockToken}
              onChange={(e) => setMockToken(e.target.value)}
              placeholder="Paste a signed RS256 JWT from MockOidcIssuer..."
              required
            />
          </label>
          <button type="submit" className="primary-btn">
            Sign in (Mock Entra ID)
          </button>
        </form>
      )}

      {error && <p className="error-text">{error}</p>}
    </section>
  );
}
