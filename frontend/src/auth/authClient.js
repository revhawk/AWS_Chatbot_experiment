/**
 * Authentication client supporting both Microsoft Entra ID (OIDC PKCE)
 * and Mock OIDC mode for sandbox/offline testing (Control C1).
 */

export function buildEntraAuthorizeUrl(config, state, codeChallenge) {
  if (!config.tenantId || !config.clientId) {
    throw new Error("Entra ID tenantId and clientId are required when authMode is 'entra_id'");
  }
  const params = new URLSearchParams({
    client_id: config.clientId,
    response_type: "code",
    redirect_uri: config.redirectUri,
    response_mode: "query",
    scope: `openid profile ${config.scope}`.trim(),
    state,
    code_challenge: codeChallenge,
    code_challenge_method: "S256",
  });
  return `https://login.microsoftonline.com/${encodeURIComponent(config.tenantId)}/oauth2/v2.0/authorize?${params.toString()}`;
}

export function createMockSession(accessToken, displayName = "Authenticated User (Mock)") {
  const token = String(accessToken || "").trim();
  if (!token) {
    throw new Error("A mock Bearer JWT token is required to sign in");
  }
  return {
    accessToken: token,
    displayName: String(displayName || "").trim() || "Authenticated User (Mock)",
    authMode: "mock_oidc",
  };
}
