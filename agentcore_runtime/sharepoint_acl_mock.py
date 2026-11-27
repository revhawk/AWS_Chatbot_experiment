"""Mock SharePoint X.509 connector & ACL-trimmed retrieval adapter for local testing.

Demonstrates how:
  1. An X.509 certificate + private key secret (stored in AWS Secrets Manager) authenticates
     the SharePoint connector app-only (Sites.Selected) so SharePoint ACLs are crawled.
  2. At query time, retrieved chunks are security-trimmed against the caller's verified
     Entra ID user_id and group memberships (Deny overrides Allow, matching SharePoint ACLs).
"""

from dataclasses import dataclass, field

from agentcore_runtime.use_cases import RetrievedChunk


class SharePointX509ConfigError(ValueError):
    """Raised when the X.509 SharePoint connector credential payload is invalid."""


@dataclass(frozen=True)
class SharePointX509Credential:
    tenant_id: str
    client_id: str
    certificate_pem: str
    private_key_pem: str
    thumbprint: str
    permission_scope: str = "Sites.Selected"
    preserve_acls: bool = True

    def validate(self) -> None:
        if not self.tenant_id.strip() or not self.client_id.strip():
            raise SharePointX509ConfigError("tenant_id and client_id are required.")
        if "-----BEGIN CERTIFICATE-----" not in self.certificate_pem:
            raise SharePointX509ConfigError("certificate_pem must be a valid PEM-encoded X.509 certificate.")
        if "-----BEGIN " not in self.private_key_pem or "PRIVATE KEY-----" not in self.private_key_pem:
            raise SharePointX509ConfigError("private_key_pem must be a valid PEM-encoded private key.")
        if len(self.thumbprint.strip()) < 32:
            raise SharePointX509ConfigError("thumbprint must be a valid SHA-1/SHA-256 hex digest.")
        if self.permission_scope not in ("Sites.Selected", "Sites.Read.All"):
            raise SharePointX509ConfigError("permission_scope must be Sites.Selected or Sites.Read.All.")
        if not self.preserve_acls:
            raise SharePointX509ConfigError("preserve_acls must be True to enforce SharePoint security trimming.")

    @classmethod
    def from_secret_dict(cls, data: dict) -> "SharePointX509Credential":
        cred = cls(
            tenant_id=str(data.get("tenantId", "")),
            client_id=str(data.get("clientId", "")),
            certificate_pem=str(data.get("certificate", "")),
            private_key_pem=str(data.get("privateKey", "")),
            thumbprint=str(data.get("thumbprint", "")),
            permission_scope=str(data.get("permissionScope", "Sites.Selected")),
            preserve_acls=bool(data.get("preserveAcls", False)),
        )
        cred.validate()
        return cred


@dataclass(frozen=True)
class SharePointAclDocument:
    """Represents a SharePoint document chunk with its crawled SharePoint ACLs."""

    text: str
    sharepoint_url: str
    allowed_users: tuple[str, ...] = field(default_factory=tuple)
    allowed_groups: tuple[str, ...] = field(default_factory=tuple)
    denied_users: tuple[str, ...] = field(default_factory=tuple)

    def is_accessible_by(self, user_id: str, user_groups: set[str]) -> bool:
        if not user_id:
            return False
        # SharePoint ACL semantics: explicit Deny always overrides Allow.
        if user_id in self.denied_users:
            return False
        if user_id in self.allowed_users:
            return True
        return bool(set(self.allowed_groups) & user_groups)


class AclTrimmedSharePointKbMock:
    """Mock KnowledgeBasePort that enforces SharePoint ACLs using X.509-crawled permissions."""

    def __init__(
        self,
        credential: SharePointX509Credential,
        documents: list[SharePointAclDocument],
        user_group_directory: dict[str, set[str]],
    ):
        credential.validate()
        self._credential = credential
        self._documents = documents
        self._directory = user_group_directory

    def retrieve(self, query: str, user_id: str) -> list[RetrievedChunk]:
        user_groups = self._directory.get(user_id, set())
        tokens = [t.lower() for t in query.split() if len(t) > 2]
        results: list[RetrievedChunk] = []
        for doc in self._documents:
            if not doc.is_accessible_by(user_id, user_groups):
                continue
            if not tokens or any(tok in doc.text.lower() for tok in tokens):
                results.append(RetrievedChunk(text=doc.text, source_uri=doc.sharepoint_url))
        return results
