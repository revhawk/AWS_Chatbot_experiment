# Implementation Tasks: SharePoint → Bedrock Knowledge Base

- [ ] 1. **Document Entra ID App Registration prerequisite** — Add step-by-step `Sites.Selected` grant instructions to `docs/GETTING_STARTED.md` — Verify: `grep -n "Sites.Selected" docs/GETTING_STARTED.md`
- [ ] 2. **Add Secrets Manager + SharePoint variables to Terraform** — Update `infra/terraform/modules/knowledge_base/{variables.tf,main.tf}` with `enable_sharepoint_source`, `sharepoint_site_urls`, `sharepoint_tenant_id`, and `sharepoint_secret_arn` — Verify: `terraform -chdir=infra/terraform/stacks/persistent validate`
- [ ] 3. **Scope KB IAM role** — Conditionally attach `secretsmanager:GetSecretValue` (plus `kms:Decrypt`) when `enable_sharepoint_source = true` — Verify: `python3 -m unittest tests/test_terraform_tda.py -v`
- [ ] 4. **Support SharePoint citations in `backend/` and `lambda/`** — Ensure `sharePointLocation.url` is extracted and deduplicated in `backend/adapters/ai/agentcore_gateway.py` and `lambda/handler.py` — Verify: `python3 -m unittest discover -s tests -v`
- [ ] 5. **Add unit & contract tests** — Add mock SharePoint citation and `Sites.Selected` config validation tests in `tests/` — Verify: `python3 tests/mutation_test.py`
- [ ] 6. **Run `code-diff-review` & update docs** — Review diff and update `docs/ARCHITECTURE.md` once implemented — Verify: `git status`
