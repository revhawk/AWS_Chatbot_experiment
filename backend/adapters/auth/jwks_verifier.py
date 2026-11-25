"""Layer 3 Auth Adapter: RS256 JWKS JWT verification (Entra ID & Mock OIDC — Control C1)."""

from datetime import datetime, timedelta, timezone
import json
import urllib.request

import jwt
from cryptography.hazmat.primitives.asymmetric import rsa

from backend.domain.entities import VerifiedUser
from backend.domain.errors import UnauthorizedError


class JwksTokenVerifier:
    """Verifies Bearer JWTs against an Entra ID or Mock OIDC JWKS endpoint using RS256 only."""

    ALLOWED_ALGORITHMS = ["RS256"]

    def __init__(
        self,
        issuer: str,
        audience: str,
        jwks_url: str | None = None,
        jwks_dict: dict | None = None,
    ):
        if not jwks_url and not jwks_dict:
            raise ValueError("Either jwks_url or jwks_dict must be provided")
        self._issuer = issuer
        self._audience = audience
        self._jwks_url = jwks_url
        self._jwks_dict = jwks_dict

    def _load_jwks(self) -> dict:
        if self._jwks_dict is not None:
            return self._jwks_dict
        try:
            with urllib.request.urlopen(self._jwks_url, timeout=5) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except Exception as exc:
            raise UnauthorizedError("Unable to fetch OIDC signing keys") from exc

    def _resolve_signing_key(self, kid: str | None):
        jwks = self._load_jwks()
        keys = jwks.get("keys", [])
        for jwk_data in keys:
            if kid is None or jwk_data.get("kid") == kid:
                return jwt.algorithms.RSAAlgorithm.from_jwk(json.dumps(jwk_data))
        raise UnauthorizedError("Token signing key not found in JWKS")

    def verify_bearer_token(self, authorization_header: str | None) -> VerifiedUser:
        if not authorization_header or not isinstance(authorization_header, str):
            raise UnauthorizedError("Missing Authorization header")

        parts = authorization_header.strip().split(" ", 1)
        if len(parts) != 2 or parts[0].lower() != "bearer" or not parts[1].strip():
            raise UnauthorizedError("Authorization header must use Bearer token")

        token = parts[1].strip()
        try:
            header = jwt.get_unverified_header(token)
        except jwt.PyJWTError as exc:
            raise UnauthorizedError("Malformed JWT header") from exc

        if header.get("alg") != "RS256":
            raise UnauthorizedError("Unsupported JWT signing algorithm")

        public_key = self._resolve_signing_key(header.get("kid"))

        try:
            claims = jwt.decode(
                token,
                key=public_key,
                algorithms=self.ALLOWED_ALGORITHMS,
                audience=self._audience,
                issuer=self._issuer,
                options={"require": ["exp", "iss", "aud"]},
            )
        except jwt.ExpiredSignatureError as exc:
            raise UnauthorizedError("Token has expired") from exc
        except jwt.PyJWTError as exc:
            raise UnauthorizedError("Invalid or unverifiable JWT token") from exc

        # Entra ID uses 'oid' (object ID) or 'sub' as the canonical user identifier.
        user_id = claims.get("oid") or claims.get("sub")
        if not isinstance(user_id, str) or not user_id.strip():
            raise UnauthorizedError("Token missing required user identity claim (oid/sub)")

        display_name = str(claims.get("name") or claims.get("preferred_username") or "")
        raw_roles = claims.get("roles") or []
        roles = tuple(str(r) for r in raw_roles) if isinstance(raw_roles, list) else ()
        return VerifiedUser(user_id=user_id.strip(), display_name=display_name, roles=roles)


class MockOidcIssuer:
    """Real RS256 OIDC issuer for offline tests and mock Entra ID lab deployments."""

    def __init__(
        self,
        issuer: str = "https://mock-entra.local/v2.0",
        audience: str = "api://bedrock-rag-assistant",
        kid: str = "mock-key-1",
    ):
        self.issuer = issuer
        self.audience = audience
        self.kid = kid
        self._private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        self._public_key = self._private_key.public_key()

    def jwks(self) -> dict:
        jwk_dict = json.loads(jwt.algorithms.RSAAlgorithm.to_jwk(self._public_key))
        jwk_dict["kid"] = self.kid
        jwk_dict["use"] = "sig"
        jwk_dict["alg"] = "RS256"
        return {"keys": [jwk_dict]}

    def issue_token(
        self,
        user_id: str,
        display_name: str = "Test User",
        roles: list[str] | None = None,
        expires_in_seconds: int = 3600,
        issuer_override: str | None = None,
        audience_override: str | None = None,
    ) -> str:
        now = datetime.now(timezone.utc)
        payload = {
            "oid": user_id,
            "sub": user_id,
            "name": display_name,
            "roles": roles or ["user"],
            "iss": issuer_override or self.issuer,
            "aud": audience_override or self.audience,
            "iat": int(now.timestamp()),
            "exp": int((now + timedelta(seconds=expires_in_seconds)).timestamp()),
        }
        return jwt.encode(payload, self._private_key, algorithm="RS256", headers={"kid": self.kid})
