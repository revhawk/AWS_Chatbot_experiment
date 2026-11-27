"""Unit & contract tests for SharePoint X.509 certificate auth and ACL-preserving retrieval."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from agentcore_runtime.sharepoint_acl_mock import (
    AclTrimmedSharePointKbMock,
    SharePointAclDocument,
    SharePointX509ConfigError,
    SharePointX509Credential,
)
from agentcore_runtime.use_cases import AnswerGroundedQuestionUseCase, GuardrailVerdict

REPO_ROOT = Path(__file__).resolve().parent.parent


class _AllowAllGuardrail:
    def check_input(self, text: str) -> GuardrailVerdict:
        return GuardrailVerdict(intervened=False)


class _NoOpMemory:
    def load_turns(self, user_id: str, session_id: str) -> list[dict]:
        return []

    def save_turn(self, user_id: str, session_id: str, prompt: str, answer: str) -> None:
        return None


class _EchoModel:
    def generate(self, prompt: str, chunks, history) -> tuple[str, bool]:
        if not chunks:
            return "No authorized documents found.", False
        return " | ".join(c.text for c in chunks), False


class TestSharePointX509AndAclPreservation(unittest.TestCase):
    def _sample_credential(self) -> SharePointX509Credential:
        return SharePointX509Credential(
            tenant_id="11111111-1111-1111-1111-111111111111",
            client_id="22222222-2222-2222-2222-222222222222",
            certificate_pem="-----BEGIN CERTIFICATE-----\nMOCKCERT\n-----END CERTIFICATE-----",
            private_key_pem="-----BEGIN PRIVATE KEY-----\nMOCKKEY\n-----END PRIVATE KEY-----",
            thumbprint="A" * 40,
            permission_scope="Sites.Selected",
            preserve_acls=True,
        )

    def test_mock_x509_script_generates_valid_cert_key_and_secret_payload(self):
        with tempfile.TemporaryDirectory() as tmp:
            res = subprocess.run(
                ["bash", str(REPO_ROOT / "scripts/mock_sharepoint_x509.sh"), "--out-dir", tmp],
                cwd=REPO_ROOT,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(res.returncode, 0, res.stderr)
            payload_path = Path(tmp) / "sharepoint_secret_payload.json"
            self.assertTrue(payload_path.exists())
            payload = json.loads(payload_path.read_text(encoding="utf-8"))
            cred = SharePointX509Credential.from_secret_dict(payload)
            self.assertEqual(cred.permission_scope, "Sites.Selected")
            self.assertTrue(cred.preserve_acls)
            self.assertEqual(len(cred.thumbprint), 40)

    def test_credential_rejects_invalid_pem_scope_or_disabled_acl(self):
        with self.assertRaises(SharePointX509ConfigError):
            SharePointX509Credential.from_secret_dict({"tenantId": "", "clientId": "c"})
        with self.assertRaises(SharePointX509ConfigError):
            SharePointX509Credential(
                tenant_id="t",
                client_id="c",
                certificate_pem="not-a-cert",
                private_key_pem="-----BEGIN PRIVATE KEY-----\nk\n-----END PRIVATE KEY-----",
                thumbprint="A" * 40,
            ).validate()
        with self.assertRaises(SharePointX509ConfigError):
            SharePointX509Credential(
                tenant_id="t",
                client_id="c",
                certificate_pem="-----BEGIN CERTIFICATE-----\nc\n-----END CERTIFICATE-----",
                private_key_pem="not-a-key",
                thumbprint="A" * 40,
            ).validate()
        with self.assertRaises(SharePointX509ConfigError):
            SharePointX509Credential(
                tenant_id="t",
                client_id="c",
                certificate_pem="-----BEGIN CERTIFICATE-----\nc\n-----END CERTIFICATE-----",
                private_key_pem="-----BEGIN PRIVATE KEY-----\nk\n-----END PRIVATE KEY-----",
                thumbprint="short",
            ).validate()
        with self.assertRaises(SharePointX509ConfigError):
            SharePointX509Credential(
                tenant_id="t",
                client_id="c",
                certificate_pem="-----BEGIN CERTIFICATE-----\nc\n-----END CERTIFICATE-----",
                private_key_pem="-----BEGIN PRIVATE KEY-----\nk\n-----END PRIVATE KEY-----",
                thumbprint="A" * 40,
                permission_scope="Sites.Write.All",
            ).validate()
        with self.assertRaises(SharePointX509ConfigError):
            SharePointX509Credential(
                tenant_id="t",
                client_id="c",
                certificate_pem="-----BEGIN CERTIFICATE-----\nc\n-----END CERTIFICATE-----",
                private_key_pem="-----BEGIN PRIVATE KEY-----\nk\n-----END PRIVATE KEY-----",
                thumbprint="A" * 40,
                preserve_acls=False,
            ).validate()

    def test_mock_x509_script_rejects_bad_scope_and_uploads_secret_with_mock_aws(self):
        with tempfile.TemporaryDirectory() as tmp:
            # Invalid scope rejected
            env_bad = {**os.environ, "SHAREPOINT_PERMISSION_SCOPE": "Sites.FullControl.All"}
            res_bad = subprocess.run(
                ["bash", str(REPO_ROOT / "scripts/mock_sharepoint_x509.sh"), "--out-dir", tmp],
                cwd=REPO_ROOT,
                env=env_bad,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(res_bad.returncode, 0)
            self.assertIn("SHAREPOINT_PERMISSION_SCOPE", res_bad.stderr)

            # --upload-secret invokes aws secretsmanager put-secret-value
            aws_log = Path(tmp) / "aws.log"
            mock_aws = Path(tmp) / "aws"
            mock_aws.write_text(f"#!/usr/bin/env bash\necho \"$*\" >> \"{aws_log}\"\nexit 0\n", encoding="utf-8")
            mock_aws.chmod(0o755)
            env_upload = {**os.environ, "PATH": f"{tmp}:{os.environ['PATH']}"}
            res_up = subprocess.run(
                [
                    "bash",
                    str(REPO_ROOT / "scripts/mock_sharepoint_x509.sh"),
                    "--out-dir",
                    tmp,
                    "--upload-secret",
                    "arn:aws:secretsmanager:eu-west-1:123456789012:secret:sp-x509",
                ],
                cwd=REPO_ROOT,
                env=env_upload,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(res_up.returncode, 0, res_up.stderr)
            self.assertIn("secretsmanager put-secret-value", aws_log.read_text(encoding="utf-8"))

        # Empty user_id gets zero results
        doc = SharePointAclDocument(text="Secret", sharepoint_url="https://x", allowed_groups=("g",))
        self.assertFalse(doc.is_accessible_by("", {"g"}))

    def test_acl_trimmed_retrieval_enforces_sharepoint_groups_and_explicit_deny(self):
        docs = [
            SharePointAclDocument(
                text="All-staff holiday policy 2026.",
                sharepoint_url="https://contoso.sharepoint.com/sites/intranet/holiday.pdf",
                allowed_groups=("grp-all-staff",),
            ),
            SharePointAclDocument(
                text="Finance Q4 budget forecast.",
                sharepoint_url="https://contoso.sharepoint.com/sites/finance/q4-budget.pdf",
                allowed_groups=("grp-finance",),
                denied_users=("user-contractor",),
            ),
            SharePointAclDocument(
                text="Executive M&A confidential memo.",
                sharepoint_url="https://contoso.sharepoint.com/sites/exec/memo.pdf",
                allowed_users=("user-cfo",),
            ),
        ]
        directory = {
            "user-finance": {"grp-all-staff", "grp-finance"},
            "user-contractor": {"grp-all-staff", "grp-finance"},
            "user-cfo": {"grp-all-staff", "grp-finance"},
        }
        kb = AclTrimmedSharePointKbMock(self._sample_credential(), docs, directory)
        use_case = AnswerGroundedQuestionUseCase(
            guardrail=_AllowAllGuardrail(),
            knowledge_base=kb,
            memory=_NoOpMemory(),
            model=_EchoModel(),
        )

        # Finance user gets All-Staff + Finance, never Exec memo
        fin_res = use_case.execute("user-finance", "s1", "budget holiday memo")
        self.assertIn("Finance Q4 budget", fin_res.answer)
        self.assertNotIn("Executive M&A", fin_res.answer)

        # Explicitly denied contractor in grp-finance is blocked from Finance doc
        contractor_res = use_case.execute("user-contractor", "s2", "budget")
        self.assertNotIn("Finance Q4 budget", contractor_res.answer)
        self.assertFalse(contractor_res.grounded)

        # CFO gets Exec memo via direct user ACL
        cfo_res = use_case.execute("user-cfo", "s3", "memo")
        self.assertIn("Executive M&A", cfo_res.answer)
        self.assertEqual(cfo_res.sources, ("https://contoso.sharepoint.com/sites/exec/memo.pdf",))

    def test_terraform_sharepoint_x509_module_security_contracts(self):
        tf = (REPO_ROOT / "infra/terraform/modules/sharepoint_x509/main.tf").read_text(encoding="utf-8")
        self.assertIn("aws_secretsmanager_secret", tf)
        self.assertIn("kms_key_id              = var.kms_key_arn", tf)
        self.assertIn('type = "SHAREPOINT"', tf)
        self.assertIn("OAUTH2_SHAREPOINT_APP_ONLY_CLIENT_CREDENTIALS", tf)
        self.assertIn("credentials_secret_arn = aws_secretsmanager_secret.sharepoint_x509.arn", tf)
        self.assertIn("secretsmanager:GetSecretValue", tf)
        self.assertNotIn("BEGIN PRIVATE KEY", tf)


if __name__ == "__main__":
    unittest.main()
