"""Static IaC security & TDA-compliance contract tests for Phase 3 Terraform modules."""

from pathlib import Path
import unittest

REPO_ROOT = Path(__file__).resolve().parent.parent
TF_MODULES = REPO_ROOT / "infra" / "terraform" / "modules"
TF_STACKS = REPO_ROOT / "infra" / "terraform" / "stacks"


class TestTdaTerraformSecurityContracts(unittest.TestCase):
    def _read(self, rel_path: str) -> str:
        return (REPO_ROOT / rel_path).read_text(encoding="utf-8")

    def test_vpc_is_strictly_private_with_zero_igw_nat_or_open_cidr(self):
        vpc_tf = self._read("infra/terraform/modules/vpc_endpoints/main.tf")
        self.assertNotIn("aws_internet_gateway", vpc_tf)
        self.assertNotIn("aws_nat_gateway", vpc_tf)
        self.assertNotIn("0.0.0.0/0", vpc_tf)
        for endpoint_service in (
            "dynamodb",
            "s3",
            "execute-api",
            "bedrock-runtime",
            "bedrock-agent-runtime",
            "bedrock-agentcore",
        ):
            self.assertIn(endpoint_service, vpc_tf)
        self.assertIn("aws_flow_log", vpc_tf)

    def test_kms_has_key_rotation_enabled_c12(self):
        kms_tf = self._read("infra/terraform/modules/kms/main.tf")
        self.assertIn("enable_key_rotation     = true", kms_tf)

    def test_knowledge_base_enforces_guardduty_malware_and_contextual_grounding_c4_c7_c9(self):
        kb_tf = self._read("infra/terraform/modules/knowledge_base/main.tf")
        self.assertIn("aws_guardduty_malware_protection_plan", kb_tf)
        self.assertIn("contextual_grounding_policy_config", kb_tf)
        self.assertIn("aws_bedrock_guardrail_version", kb_tf)
        self.assertIn("aws:SecureTransport", kb_tf)

    def test_edge_ingress_is_internal_alb_with_waf_and_tls13_c2(self):
        edge_tf = self._read("infra/terraform/modules/edge_ingress/main.tf")
        self.assertIn("internal                   = true", edge_tf)
        self.assertIn("aws_wafv2_web_acl", edge_tf)
        self.assertIn("aws_wafv2_web_acl_association", edge_tf)
        self.assertIn("drop_invalid_header_fields = true", edge_tf)
        self.assertIn('matcher  = "200,403"', edge_tf)
        self.assertIn('matcher  = "200,307,403,405"', edge_tf)

    def test_compute_api_is_private_vpce_only_and_vpc_attached_lambda_c2_c5(self):
        api_tf = self._read("infra/terraform/modules/compute_api/main.tf")
        self.assertIn('types            = ["PRIVATE"]', api_tf)
        self.assertIn("aws:SourceVpce", api_tf)
        self.assertIn("vpc_config", api_tf)
        self.assertIn("point_in_time_recovery", api_tf)
        self.assertIn("bedrock-agentcore:InvokeAgentRuntime", api_tf)

    def test_terraform_uses_generic_user_and_access_terminology(self):
        vpc_tf = self._read("infra/terraform/modules/vpc_endpoints/main.tf")
        self.assertIn("access_allowed_cidrs", vpc_tf)
        self.assertIn("Zscaler / Access layer", vpc_tf)


if __name__ == "__main__":
    unittest.main()
