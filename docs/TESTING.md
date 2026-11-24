# Testing & Validation Guide

This project uses a **3-layer testing strategy** designed for fast offline feedback (`$0` AWS cost) plus a lightweight live smoke test after deployment.

---

## 1. Quick Commands (Offline, `$0` Cost)

Run from the repository root (requires only Python 3 stdlib and Bash — no AWS credentials or `pip install` needed):

```bash
# 1. Shell & Python syntax checks
bash -n deploy.sh teardown.sh scripts/*.sh scripts/lib/common.sh
python3 -m py_compile lambda/handler.py chat_cli.py

# 2. Unit & API contract tests (29 tests)
python3 -m unittest discover -s tests -v

# 3. Full-repo mutation testing (79 mutants across all Python & Bash files)
python3 tests/mutation_test.py
```

---

## 2. Offline Test Suites (`tests/`)

| File | Scope | What It Verifies |
| :--- | :--- | :--- |
| `tests/test_handler.py` | Lambda unit, API contract & Guardrail policies | `KB_MODE=vector` (`retrieve_and_generate`) and `KB_MODE=managed` (`retrieve` + `converse`); default env fallbacks (`vector`/`single`); S3, SharePoint (`sharePointLocation.url`), and Web citation extraction & deduplication; `MEMORY_MODE=multi` DynamoDB history ordering (`ScanIndexForward=False`); Guardrail ID/version wiring, `INTERVENED` mapping, PII anonymization pass-through, and DynamoDB audit logging; embedded JSON policy validation for `scripts/guardrail.sh` (6 content filters, `PROFANITY` + custom word `"Poo"`, 31 PII anonymizers); HTTP error contracts (`400`, `429`, `500`, `502`) and DynamoDB write resilience. |
| `tests/test_cli.py` | CLI & in-process client→server contract | Missing env var exit (`RAG_API_URL`/`RAG_API_KEY`); `POST` headers (`x-api-key`, `Content-Type`), payload, `session_id` tracking, and source printing; `HTTPError`, `URLError`, non-JSON, and `EOFError` handling; **in-process contract test** wiring `chat_cli.py` directly into `lambda/handler.py` to catch any request/response schema drift. |
| `tests/test_scripts.py` | Bash infrastructure modules (mocked `aws` CLI) | `validate_slug`, `save_config_var` / `clear_config_var`, and all tag formatters in `scripts/lib/common.sh`; KB, Guardrail, and DynamoDB reuse/skip behavior; Resource Group re-tagging of reused resources (`retag_reused_resources`); `deploy.sh` validation of `KB_MODE` and `SHAREPOINT_PERMISSION_SCOPE`; `pre_deploy_check` build plan and leftover resource warnings; `teardown.sh` requiring exact uppercase `YES` to keep the Knowledge Base. |
| `tests/mutation_test.py` | Full-repo mutation testing | Injects controlled AST mutations into `lambda/handler.py` and `chat_cli.py`, and targeted conditional/constant mutations into all 9 Bash scripts, re-running `unittest` after each mutant and restoring the original file. Fails with exit code `1` if any mutant survives. |

---

## 3. Post-Deploy Live E2E Smoke & Guardrail Checks (`scripts/checks.sh`)

At the end of `./deploy.sh`, `post_deploy_smoke_test` waits 5 seconds for API Gateway and Lambda readiness, then runs **5 live `POST /chat` checks** against the deployed endpoint:

| # | Check | Expected Result |
| :---: | :--- | :--- |
| 1 | **Auth rejection** (no `x-api-key` header) | HTTP `403` (`$0` Bedrock token cost) |
| 2 | **RAG sample query** (`SMOKE_TEST_PROMPT`) | HTTP `200`, non-empty answer, citations printed |
| 3 | **Guardrail: custom word block** (`"Poo"`) | HTTP `200`, `guardrail_action == "INTERVENED"` |
| 4 | **Guardrail: prompt attack block** | HTTP `200`, `guardrail_action == "INTERVENED"` |
| 5 | **Guardrail: PII anonymization** (email + UK phone) | HTTP `200`, raw PII not echoed back in response |

### Customizing or Skipping the Smoke Test
- Customize the sample prompt in `config.env`:
  ```bash
  SMOKE_TEST_PROMPT="Summarize the key architecture decisions in 2 sentences."
  ```
- Skip the post-deploy smoke test for a single run or via config:
  ```bash
  ./deploy.sh --skip-smoke-test
  # or in config.env:
  RUN_SMOKE_TEST="false"
  ```

---

## 4. Recommended Pre-Commit Checklist

Before committing changes:
1. Run `bash -n deploy.sh teardown.sh scripts/*.sh scripts/lib/common.sh` (and `shellcheck` if installed).
2. Run `python3 -m py_compile lambda/handler.py chat_cli.py`.
3. Run `python3 -m unittest discover -s tests -v` — confirm all tests pass.
4. Run `python3 tests/mutation_test.py` — confirm **100% mutation score** (0 surviving mutants).
