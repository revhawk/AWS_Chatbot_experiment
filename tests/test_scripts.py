"""Offline tests for Bash scripts using a mocked AWS CLI on PATH."""

import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent


def _create_mock_aws(bin_dir: Path, log_file: Path, behavior_script: str = ""):
    """Create a mock `aws` executable that logs calls and returns canned outputs."""
    aws_path = bin_dir / "aws"
    script = f"""#!/usr/bin/env bash
echo "$*" >> "{log_file}"
{behavior_script}
exit 0
"""
    aws_path.write_text(script, encoding="utf-8")
    aws_path.chmod(aws_path.stat().st_mode | stat.S_IEXEC)


def _run_bash(cmd: str, env_extra=None, stdin_text=None, cwd=None):
    env = os.environ.copy()
    if env_extra:
        env.update(env_extra)
    return subprocess.run(
        ["bash", "-c", cmd],
        cwd=cwd or REPO_ROOT,
        env=env,
        input=stdin_text,
        text=True,
        capture_output=True,
    )


class TestCommonHelpers(unittest.TestCase):
    def test_validate_slug_accepts_valid_and_rejects_invalid(self):
        ok = _run_bash("source scripts/lib/common.sh && validate_slug 'my-app-1' 'App'")
        self.assertEqual(ok.returncode, 0)

        for bad in ("MyApp", "-leading", "trailing-", "double--hyphen", "has space"):
            res = _run_bash(f"source scripts/lib/common.sh && validate_slug '{bad}' 'App'")
            self.assertNotEqual(res.returncode, 0, f"Expected failure for slug '{bad}'")

    def test_save_and_clear_config_var(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg = Path(tmp) / "config.env"
            res = _run_bash(
                f"""
                set -euo pipefail
                SCRIPT_DIR="{REPO_ROOT}"
                source scripts/lib/common.sh
                save_config_var "{cfg}" "KB_NAME" "lab-kb-1"
                save_config_var "{cfg}" "KB_ID" "KB123"
                save_config_var "{cfg}" "CUSTOM_KEY" "custom-val"
                save_config_var "{cfg}" "KB_ID" "KB999"
                clear_config_var "{cfg}" "KB_NAME"
                """
            )
            self.assertEqual(res.returncode, 0, res.stderr)
            text = cfg.read_text(encoding="utf-8")
            self.assertIn('# KB_NAME=""', text)
            self.assertIn('KB_ID="KB999"', text)
            self.assertIn('CUSTOM_KEY="custom-val"', text)

    def test_tag_formatters_include_all_required_tags(self):
        res = _run_bash(
            """
            source scripts/lib/common.sh
            FULL_PREFIX="lab-rag" APP_NAME="rag" STAGE="dev" SUFFIX="123" TAG_COST_CENTRE="IT" TAG_RESOURCE_ID="001"
            echo "KV=$(tags_kv)"
            echo "BEDROCK=$(tags_bedrock_kv)"
            echo "IAM=$(tags_iam)"
            echo "S3=$(tags_s3)"
            """
        )
        self.assertEqual(res.returncode, 0)
        for expected in (
            "KV=Name=lab-rag,Project=rag,Stage=dev,Stack=123,CostCentre=IT,ResourceID=001",
            "key=Name,value=lab-rag",
            "Key=Name,Value=lab-rag",
            "TagSet=[{Key=Name,Value=lab-rag}",
        ):
            self.assertIn(expected, res.stdout)


class TestModuleReuseAndTeardown(unittest.TestCase):
    def test_storage_skips_create_when_reused_and_preserves_when_keep_kb(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "aws.log"
            _create_mock_aws(Path(tmp), log)
            env = {"PATH": f"{tmp}:{os.environ['PATH']}"}

            res = _run_bash(
                """
                set -euo pipefail
                source scripts/storage.sh
                AWS_REGION="eu-west-1" KB_REUSED="true" KB_NAME="lab-kb-1" KB_ID="KB1"
                deploy_storage
                KEEP_KB="true" SOURCE_BUCKET="s1" SUPP_BUCKET="s2" VECTOR_BUCKET="v1" VECTOR_INDEX="idx"
                teardown_storage
                """,
                env_extra=env,
            )
            self.assertEqual(res.returncode, 0, res.stderr)
            self.assertFalse(log.exists(), "Expected zero AWS CLI calls when KB reused/preserved")

            res_del = _run_bash(
                """
                set -euo pipefail
                source scripts/storage.sh
                AWS_REGION="eu-west-1" KEEP_KB="false" SOURCE_BUCKET="s1" SUPP_BUCKET="s2" VECTOR_BUCKET="v1" VECTOR_INDEX="idx"
                teardown_storage
                """,
                env_extra=env,
            )
            self.assertEqual(res_del.returncode, 0, res_del.stderr)
            calls = log.read_text(encoding="utf-8")
            self.assertIn("s3vectors delete-index", calls)
            self.assertIn("s3vectors delete-vector-bucket", calls)
            self.assertIn("s3 rb s3://s1 --force", calls)
            self.assertIn("s3 rb s3://s2 --force", calls)

    def test_guardrail_reuses_and_preserves_unmanaged_guardrail(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "aws.log"
            _create_mock_aws(Path(tmp), log)
            env = {"PATH": f"{tmp}:{os.environ['PATH']}"}

            res = _run_bash(
                """
                set -euo pipefail
                source scripts/guardrail.sh
                AWS_REGION="eu-west-1" GUARDRAIL_ID="xojv3g7paumh"
                deploy_guardrail
                [ "${GUARDRAIL_MANAGED}" = "false" ]
                teardown_guardrail
                """,
                env_extra=env,
            )
            self.assertEqual(res.returncode, 0, res.stderr)
            self.assertFalse(log.exists())

            res_del = _run_bash(
                """
                set -euo pipefail
                source scripts/guardrail.sh
                AWS_REGION="eu-west-1" GUARDRAIL_ID="gr-temp" GUARDRAIL_MANAGED="true"
                teardown_guardrail
                """,
                env_extra=env,
            )
            self.assertEqual(res_del.returncode, 0, res_del.stderr)
            self.assertIn("bedrock delete-guardrail --guardrail-identifier gr-temp", log.read_text())

    def test_knowledge_base_resolves_active_kb_id_and_skips_recreation(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "aws.log"
            behavior = """
if [[ "$*" == *"get-knowledge-base"* && "$*" == *"knowledgeBase.status"* ]]; then echo "ACTIVE"; exit 0; fi
if [[ "$*" == *"get-knowledge-base"* && "$*" == *"knowledgeBase.name"* ]]; then echo "lab-kb-saved"; exit 0; fi
if [[ "$*" == *"get-knowledge-base"* && "$*" == *"knowledgeBase.roleArn"* ]]; then echo "arn:aws:iam::123:role/lab-kb-role-1"; exit 0; fi
if [[ "$*" == *"list-data-sources"* ]]; then echo "DS1"; exit 0; fi
if [[ "$*" == *"get-data-source"* ]]; then echo "arn:aws:s3:::lab-docs-1"; exit 0; fi
"""
            _create_mock_aws(Path(tmp), log, behavior)
            env = {"PATH": f"{tmp}:{os.environ['PATH']}"}

            res = _run_bash(
                """
                set -euo pipefail
                source scripts/lib/common.sh
                source scripts/knowledge_base.sh
                AWS_REGION="eu-west-1" FULL_PREFIX="lab-rag" KB_ID="KB777"
                resolve_existing_knowledge_base
                [ "${KB_REUSED}" = "true" ]
                [ "${KB_MANAGED}" = "false" ]
                [ "${KB_NAME}" = "lab-kb-saved" ]
                [ "${KB_ROLE_NAME}" = "lab-kb-role-1" ]
                [ "${SOURCE_BUCKET}" = "lab-docs-1" ]
                deploy_knowledge_base
                KEEP_KB="true" teardown_knowledge_base
                """,
                env_extra=env,
            )
            self.assertEqual(res.returncode, 0, res.stderr)
            calls = log.read_text(encoding="utf-8")
            self.assertNotIn("create-knowledge-base", calls)
            self.assertNotIn("delete-knowledge-base", calls)

    def test_retag_reused_resources_tags_into_new_stack(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "aws.log"
            _create_mock_aws(Path(tmp), log)
            env = {"PATH": f"{tmp}:{os.environ['PATH']}"}

            res = _run_bash(
                """
                set -euo pipefail
                source scripts/lib/common.sh
                source scripts/resource_group.sh
                AWS_REGION="eu-west-1" ACCOUNT_ID="123456789012"
                FULL_PREFIX="lab-rag" APP_NAME="rag" STAGE="dev" SUFFIX="999" TAG_COST_CENTRE="IT" TAG_RESOURCE_ID="001"
                RESOURCE_GROUP_NAME="lab-rag-dev-999"
                KB_REUSED="true" KB_ID="KB1" SOURCE_BUCKET="src-1" SUPP_BUCKET="supp-1" KB_ROLE_NAME="kb-role-1"
                GUARDRAIL_MANAGED="false" GUARDRAIL_ID="gr-1"
                DDB_REUSED="true" DDB_TABLE="ddb-1"
                deploy_resource_group
                """,
                env_extra=env,
            )
            self.assertEqual(res.returncode, 0, res.stderr)
            calls = log.read_text(encoding="utf-8")
            self.assertIn("bedrock-agent tag-resource", calls)
            self.assertIn("s3api put-bucket-tagging --bucket src-1", calls)
            self.assertIn("iam tag-role --role-name kb-role-1", calls)
            self.assertIn("bedrock tag-resource", calls)
            self.assertIn("dynamodb tag-resource", calls)
            self.assertIn("resource-groups create-group", calls)

    def test_compute_api_reuses_ddb_table_when_ddb_reused_true(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "aws.log"
            behavior = """
if [[ "$*" == *"iam create-role"* ]]; then echo "arn:aws:iam::123:role/r"; exit 0; fi
if [[ "$*" == *"lambda create-function"* ]]; then echo "arn:aws:lambda:eu-west-1:123:function:f"; exit 0; fi
if [[ "$*" == *"apigateway create-rest-api"* ]]; then echo "api1"; exit 0; fi
if [[ "$*" == *"apigateway get-resources"* ]]; then echo "root1"; exit 0; fi
if [[ "$*" == *"apigateway create-resource"* ]]; then echo "res1"; exit 0; fi
if [[ "$*" == *"apigateway create-api-key"* ]]; then echo "key1"; exit 0; fi
if [[ "$*" == *"apigateway get-api-key"* ]]; then echo "secretval"; exit 0; fi
if [[ "$*" == *"apigateway create-usage-plan"* ]]; then echo "plan1"; exit 0; fi
"""
            _create_mock_aws(Path(tmp), log, behavior)
            # Also stub sleep so test runs instantaneously
            sleep_stub = Path(tmp) / "sleep"
            sleep_stub.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
            sleep_stub.chmod(0o755)
            env = {"PATH": f"{tmp}:{os.environ['PATH']}"}

            res = _run_bash(
                """
                set -euo pipefail
                source scripts/lib/common.sh
                source scripts/compute_api.sh
                AWS_REGION="eu-west-1" ACCOUNT_ID="123456789012"
                FULL_PREFIX="lab-rag" APP_NAME="rag" STAGE="dev" SUFFIX="999" TAG_COST_CENTRE="IT" TAG_RESOURCE_ID="001"
                DDB_REUSED="true" DDB_TABLE="existing-history"
                LAMBDA_ROLE_NAME="lrole" LAMBDA_NAME="lfn" API_NAME="lapi"
                KB_ID="KB1" KB_MODE="managed" GUARDRAIL_ID="gr1" GUARDRAIL_VERSION="DRAFT" MEMORY_MODE="single"
                deploy_compute_api
                """,
                env_extra=env,
            )
            self.assertEqual(res.returncode, 0, res.stderr)
            calls = log.read_text(encoding="utf-8")
            self.assertNotIn("dynamodb create-table", calls)
            self.assertIn("KB_MODE=managed", calls)

    def test_teardown_requires_exact_uppercase_YES_to_keep_kb(self):
        for reply, expect_keep in [("YES", True), ("yes", False), ("y", False), ("", False)]:
            with tempfile.TemporaryDirectory() as tmp:
                tmp_path = Path(tmp)
                log = tmp_path / "aws.log"
                _create_mock_aws(tmp_path, log)
                cfg = tmp_path / "config.env"
                env_lab = tmp_path / ".env.lab"
                env_lab.write_text(
                    "\n".join(
                        [
                            f"CONFIG_FILE={cfg}",
                            "AWS_REGION=eu-west-1",
                            "APP_NAME=rag",
                            "PREFIX=lab",
                            "STAGE=dev",
                            "KB_NAME=lab-rag-kb-1",
                            "KB_ID=KB111",
                            "KB_ROLE_NAME=lab-kb-role-1",
                            "SOURCE_BUCKET=src-1",
                            "SUPP_BUCKET=supp-1",
                            "VECTOR_BUCKET=vec-1",
                            "VECTOR_INDEX=idx-1",
                            "GUARDRAIL_ID=gr-1",
                            "GUARDRAIL_MANAGED=false",
                            "LAMBDA_NAME=fn-1",
                            "LAMBDA_ROLE_NAME=lrole-1",
                            "DDB_TABLE=ddb-1",
                            "API_ID=api-1",
                            "API_KEY_ID=key-1",
                            "PLAN_ID=plan-1",
                            "RESOURCE_GROUP_NAME=rg-1",
                        ]
                    )
                    + "\n",
                    encoding="utf-8",
                )
                env = {"PATH": f"{tmp}:{os.environ['PATH']}"}
                res = _run_bash(
                    f'"{REPO_ROOT}/teardown.sh"',
                    env_extra=env,
                    stdin_text=f"{reply}\n",
                    cwd=tmp_path,
                )
                self.assertEqual(res.returncode, 0, f"reply={reply!r} stderr={res.stderr}")
                calls = log.read_text(encoding="utf-8")
                if expect_keep:
                    self.assertNotIn("delete-knowledge-base", calls)
                    self.assertTrue(cfg.exists())
                    self.assertIn('KB_ID="KB111"', cfg.read_text(encoding="utf-8"))
                    self.assertIn('KB_NAME="lab-rag-kb-1"', cfg.read_text(encoding="utf-8"))
                else:
                    self.assertIn("delete-knowledge-base", calls)

    def test_deploy_validates_kb_mode_and_sharepoint_scope(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg_bad_kb = Path(tmp) / "bad_kb.env"
            cfg_bad_kb.write_text(
                'STAGE="dev"\nMEMORY_MODE="single"\nAPP_NAME="rag"\nPREFIX="lab"\nTAG_COST_CENTRE="IT"\nTAG_RESOURCE_ID="001"\nKB_MODE="bogus"\n',
                encoding="utf-8",
            )
            res = _run_bash(f'./deploy.sh --config "{cfg_bad_kb}"')
            self.assertNotEqual(res.returncode, 0)
            self.assertIn("KB_MODE", res.stdout + res.stderr)

            cfg_bad_sp = Path(tmp) / "bad_sp.env"
            cfg_bad_sp.write_text(
                'STAGE="dev"\nMEMORY_MODE="single"\nAPP_NAME="rag"\nPREFIX="lab"\nTAG_COST_CENTRE="IT"\nTAG_RESOURCE_ID="001"\nKB_MODE="managed"\nSHAREPOINT_PERMISSION_SCOPE="Sites.Write.All"\n',
                encoding="utf-8",
            )
            res2 = _run_bash(f'./deploy.sh --config "{cfg_bad_sp}"')
            self.assertNotEqual(res2.returncode, 0)
            self.assertIn("SHAREPOINT_PERMISSION_SCOPE", res2.stdout + res2.stderr)

    def test_pre_deploy_check_renders_plan_and_warns_on_leftovers(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "aws.log"
            behavior = """
if [[ "$*" == *"lambda list-functions"* ]]; then echo "lab-rag-chat-old"; exit 0; fi
"""
            _create_mock_aws(Path(tmp), log, behavior)
            env = {"PATH": f"{tmp}:{os.environ['PATH']}"}
            res = _run_bash(
                """
                set -euo pipefail
                source scripts/checks.sh
                ACCOUNT_ID="123" AWS_REGION="eu-west-1" STAGE="dev" KB_MODE="managed" MEMORY_MODE="single"
                APP_NAME="rag" TAG_COST_CENTRE="IT" TAG_RESOURCE_ID="001" SHAREPOINT_PERMISSION_SCOPE="Sites.Selected"
                FULL_PREFIX="lab-rag" SUFFIX="999" KB_REUSED="true" KB_NAME="kb-1" KB_ID="KB1"
                DDB_REUSED="true" DDB_TABLE="ddb-1" LAMBDA_NAME="fn" LAMBDA_ROLE_NAME="lr" API_NAME="api" RESOURCE_GROUP_NAME="rg"
                AUTO_APPROVE="true"
                pre_deploy_check
                """,
                env_extra=env,
            )
            self.assertEqual(res.returncode, 0, res.stderr)
            self.assertIn("[REUSE]  Bedrock Knowledge Base", res.stdout)
            self.assertIn("[REUSE]  DynamoDB Table", res.stdout)
            self.assertIn("lab-rag-chat-old", res.stdout)


if __name__ == "__main__":
    unittest.main()
