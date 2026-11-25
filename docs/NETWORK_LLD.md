# Network Low-Level Design (LLD) — AWS Bedrock RAG Assistant (`eu-west-1`)

> **Audience:** Network Engineering, Firewall Administration, and Cloud Security teams.  
> **Scope:** Low-level AWS VPC, subnetting, routing, Security Groups, AWS PrivateLink (VPC Endpoints), Internal ALB, AWS WAFv2, DNS, TLS, and network observability configuration in **`eu-west-1` (Ireland)**.  
> **IaC Source of Truth:** `infra/terraform/modules/{vpc_endpoints,edge_ingress,compute_api,spa_hosting,kms,observability}` and `infra/terraform/stacks/{persistent,app}`.

---

## 1. Design Principles & Non-Functional Requirements

| Requirement | Implementation |
| :--- | :--- |
| **Zero Public Ingress** | Internal ALB (`internal = true`) in private subnets only; Private REST API Gateway (`PRIVATE`) with VPCE-only resource policy; S3 Block Public Access enabled on all buckets. |
| **Zero Public Egress** | No Internet Gateway (`IGW`) and no NAT Gateway (`NAT`). Private route tables contain **no** `0.0.0.0/0` route. |
| **End-to-End Encryption in Transit** | HTTPS / TLS 1.3 (`ELBSecurityPolicy-TLS13-1-2-2021-06`) from User → Access Layer → Internal ALB → VPCEs → AWS services; `aws:SecureTransport = false` explicitly denied on S3 bucket policies. |
| **High Availability** | Active-Active across 2 Availability Zones (`eu-west-1a`, `eu-west-1b`) for ALB, VPC-attached Lambda ENIs, AgentCore Runtime ENIs, and all 5 Interface VPC Endpoints. |
| **Least-Privilege Micro-Segmentation** | 4 dedicated Security Groups (`sg-alb`, `sg-endpoints`, `sg-lambda`, `sg-runtime`) allowing TCP `443` only between explicit SG pairs and AWS prefix lists. |

---

## 2. IP Addressing, Subnets & ENI Capacity Plan

Default VPC CIDR is `10.40.0.0/16` (override via `var.vpc_cidr` to match corporate IPAM allocation).

| Subnet Name | AZ | CIDR | Usable Host IPs | Public IP on Launch | Hosted ENIs (Estimated) |
| :--- | :---: | :---: | :---: | :---: | :--- |
| `${prefix}-private-eu-west-1a` | `eu-west-1a` | `10.40.1.0/24` | 251 | `false` | 1× Internal ALB, 5× Interface VPCEs, Lambda Hyperplane ENIs, AgentCore Runtime ENIs (~10–25 IPs) |
| `${prefix}-private-eu-west-1b` | `eu-west-1b` | `10.40.2.0/24` | 251 | `false` | 1× Internal ALB, 5× Interface VPCEs, Lambda Hyperplane ENIs, AgentCore Runtime ENIs (~10–25 IPs) |

- **VPC Settings:** `enable_dns_support = true`, `enable_dns_hostnames = true` (mandatory for Interface VPCE Private DNS).
- **IP Headroom:** `/24` per AZ provides >220 spare IPs for ALB scaling, Lambda concurrency bursts, and AgentCore Runtime microVM ENIs.

---

## 3. Route Table Specification

Single shared private route table (`${prefix}-private-rt`) associated with both private subnets:

| Destination | Target | Purpose |
| :--- | :--- | :--- |
| `10.40.0.0/16` (`var.vpc_cidr`) | `local` | Intra-VPC communication (ALB ↔ VPCEs ↔ Lambda ↔ Runtime) |
| `pl-xxxxxxxx` (AWS DynamoDB `eu-west-1` prefix list) | `vpce-xxxxxxxx` (DynamoDB Gateway VPCE) | Private Lambda → DynamoDB traffic |
| `pl-yyyyyyyy` (AWS S3 `eu-west-1` prefix list) | `vpce-yyyyyyyy` (S3 Gateway VPCE) | Private Lambda → S3 (citations & feedback CSV) traffic |
| `0.0.0.0/0` | **ABSENT (Explicitly Omitted)** | Guarantees zero route to public internet |

---

## 4. Security Group Rule Specification (Firewall Matrix)

All Security Groups are stateful, drop all unmentioned traffic by default, and permit **TCP `443` only**.

### 4.1 `sg-alb` (Internal Application Load Balancer)
| Rule ID | Direction | Protocol | Port | Source / Destination | Purpose |
| :---: | :---: | :---: | :---: | :--- | :--- |
| `ALB-IN-01` | Ingress | TCP | `443` | `var.access_allowed_cidrs` (Zscaler connector CIDRs) | User HTTPS traffic via corporate Access Layer |
| `ALB-OUT-01` | Egress | TCP | `443` | `sg-endpoints` | Forward `/` to S3 Interface VPCE & `/api/*` to `execute-api` VPCE |

### 4.2 `sg-endpoints` (All 5 Interface VPC Endpoints)
| Rule ID | Direction | Protocol | Port | Source / Destination | Purpose |
| :---: | :---: | :---: | :---: | :--- | :--- |
| `VPCE-IN-01` | Ingress | TCP | `443` | `sg-alb` | ALB → `s3` Interface VPCE & `execute-api` VPCE |
| `VPCE-IN-02` | Ingress | TCP | `443` | `sg-lambda` | Lambda → `bedrock-agentcore` VPCE |
| `VPCE-IN-03` | Ingress | TCP | `443` | `sg-runtime` | AgentCore Runtime → `bedrock-runtime` & `bedrock-agent-runtime` VPCEs |
| *(None)* | Egress | — | — | None | Interface VPCE ENIs only accept inbound connections |

### 4.3 `sg-lambda` (VPC-Attached API Lambda)
| Rule ID | Direction | Protocol | Port | Source / Destination | Purpose |
| :---: | :---: | :---: | :---: | :--- | :--- |
| *(None)* | Ingress | — | — | None | Invoked via AWS Lambda service plane by Private API Gateway |
| `LAM-OUT-01` | Egress | TCP | `443` | `sg-endpoints` | `InvokeAgentRuntime` via `bedrock-agentcore` VPCE |
| `LAM-OUT-02` | Egress | TCP | `443` | DynamoDB Gateway VPCE prefix list | `PutItem` / `Query` for audit & feedback |
| `LAM-OUT-03` | Egress | TCP | `443` | S3 Gateway VPCE prefix list | Citation PDF & feedback CSV access |

### 4.4 `sg-runtime` (AgentCore Runtime — VPC Mode)
| Rule ID | Direction | Protocol | Port | Source / Destination | Purpose |
| :---: | :---: | :---: | :---: | :--- | :--- |
| *(None)* | Ingress | — | — | None | Invoked privately via AgentCore data plane |
| `RT-OUT-01` | Egress | TCP | `443` | `sg-endpoints` | `Retrieve`, `Converse`, `ApplyGuardrail` via Bedrock Interface VPCEs |

---

## 5. VPC Endpoints & Endpoint Policies (`eu-west-1`)

| # | Service Name | Type | Private DNS | Subnets / RT | SG | Endpoint Policy |
| :-: | :--- | :---: | :---: | :--- | :---: | :--- |
| 1 | `com.amazonaws.eu-west-1.dynamodb` | Gateway | N/A | Private RT | N/A | `aws:PrincipalAccount == <account_id>` |
| 2 | `com.amazonaws.eu-west-1.s3` | Gateway | N/A | Private RT | N/A | `aws:PrincipalAccount == <account_id>` |
| 3 | `com.amazonaws.eu-west-1.s3` | Interface | `false` | Both Private Subnets | `sg-endpoints` | `aws:PrincipalAccount == <account_id>` |
| 4 | `com.amazonaws.eu-west-1.execute-api` | Interface | `true` | Both Private Subnets | `sg-endpoints` | `aws:PrincipalAccount == <account_id>` |
| 5 | `com.amazonaws.eu-west-1.bedrock-agentcore` | Interface | `true` | Both Private Subnets | `sg-endpoints` | `aws:PrincipalAccount == <account_id>` |
| 6 | `com.amazonaws.eu-west-1.bedrock-runtime` | Interface | `true` | Both Private Subnets | `sg-endpoints` | `aws:PrincipalAccount == <account_id>` |
| 7 | `com.amazonaws.eu-west-1.bedrock-agent-runtime` | Interface | `true` | Both Private Subnets | `sg-endpoints` | `aws:PrincipalAccount == <account_id>` |

> **Why `s3` Interface VPCE has `private_dns_enabled = false`:** Keeping Private DNS off on the S3 Interface VPCE avoids hijacking Gateway VPCE routing for Lambda while allowing the Internal ALB to forward static React SPA requests directly to the S3 Interface VPCE ENI private IPs.

---

## 6. Internal ALB, AWS WAFv2, TLS & Target Group Specification

### 6.1 Internal ALB Listener (`HTTPS :443`)
- **Scheme:** `internal` (private IPs in `10.40.1.0/24` and `10.40.2.0/24`)
- **TLS Policy:** `ELBSecurityPolicy-TLS13-1-2-2021-06` (TLS 1.3 preferred, TLS 1.2 minimum; TLS 1.0/1.1 disabled)
- **Certificate:** ACM certificate (`var.acm_certificate_arn`) matching the corporate application hostname
- **Header Hardening:** `drop_invalid_header_fields = true`
- **Access Logs:** Enabled → dedicated SSE-S3 (`AES256`) ALB logs bucket (`prefix = "alb-access-logs"`, ELB service account policy)

### 6.2 Listener Routing & Target Groups
| Priority | Condition | Target Group | Target Type & Targets | Health Check |
| :---: | :--- | :--- | :--- | :--- |
| **10** | Path `/api/*` | `${prefix}-api-tg` | `ip` — ENI private IPs of `execute-api` VPCE | `HTTPS :443`, path `/`, **matcher `200,403`** *(API GW returns `403` to unauthenticated root probes)* |
| **Default** | All other paths (`/`, SPA assets) | `${prefix}-spa-tg` | `ip` — ENI private IPs of `s3` Interface VPCE | `HTTPS :443`, path `/`, **matcher `200,307,403,405`** *(S3 VPCE returns `307`/`403`/`405` to root probes)* |

> **Operational Note (VPCE ENI IP Stability):** AWS Interface VPCE ENI IPs are long-lived but can change during rare AWS maintenance. Re-running `terraform apply` on `stacks/app` (or scheduling a lightweight EventBridge + Lambda IP sync) keeps ALB IP targets synchronized.

### 6.3 AWS WAFv2 Web ACL (`REGIONAL`, attached to Internal ALB)
| Priority | Rule | Action | Purpose |
| :---: | :--- | :---: | :--- |
| **10** | `AWSManagedRulesCommonRuleSet` | Count/Block (Managed) | OWASP Top 10 / L7 injection & protocol abuse protection |
| **20** | `AWSManagedRulesKnownBadInputsRuleSet` | Block (Managed) | Blocks known exploit patterns (Log4j, path traversal, etc.) |
| **30** | `RateLimitPerIp` (`limit = 500` per 5 min) | Block | Mitigates volumetric abuse / credential stuffing |

---

## 7. Resource Policies (Defense in Depth)

- **Private REST API Gateway Resource Policy (`modules/compute_api`):**
  - Explicit `Deny` on `execute-api:Invoke` when `aws:SourceVpce != <execute-api-vpce-id>`
  - Explicit `Allow` on `execute-api:Invoke` only when `aws:SourceVpce == <execute-api-vpce-id>`
- **React SPA S3 Bucket Policy (`modules/spa_hosting`):**
  - Explicit `Deny` on `s3:*` when `aws:SecureTransport == false`
  - Explicit `Allow` on `s3:GetObject` only when `aws:SourceVpce == <s3-interface-vpce-id>`
- **Knowledge Docs & Audit S3 Bucket Policies:**
  - Block Public Access (`all 4 flags = true`), KMS CMK encryption (`aws:kms`), explicit `Deny` on `aws:SecureTransport == false`.

---

## 8. DNS & Authentication Path (Entra ID / Mock OIDC)

1. **Application DNS:** Corporate private DNS resolves `https://<app-hostname>` → Internal ALB DNS name (private IPs in `10.40.1.x` / `10.40.2.x`).
2. **User Sign-In:** Browser (via Zscaler) signs in to Microsoft Entra ID (or Mock OIDC in sandbox) and receives a signed RS256 JWT (`Authorization: Bearer <token>`).
3. **API Token Verification (`C1`):** VPC Lambda verifies RS256 signature, `iss`, `aud`, and `exp` against JWKS (`ENTRA_JWKS_URL`) on every `/api/*` request. *(Note: in a zero-egress VPC, either cache/bundle JWKS keys in KMS-encrypted Secrets Manager/SSM via a VPCE, or serve JWKS over an internal private endpoint reachable from the VPC.)*

---

## 9. Network Observability & Verification Commands

| Log Source | Destination | Retention | Encryption |
| :--- | :--- | :---: | :---: |
| **VPC Flow Logs (`ALL`)** | CloudWatch `/aws/vpc/${prefix}-flow-logs` | 90 days | KMS CMK |
| **Internal ALB Access Logs** | S3 `${prefix}-audit-logs-${acct}/alb-access-logs/` | S3 lifecycle | KMS CMK |
| **CloudTrail (Management Events)** | S3 `${prefix}-audit-logs-${acct}/AWSLogs/` | S3 lifecycle | KMS CMK |
| **Lambda & Bedrock Invocation Logs** | CloudWatch `/aws/lambda/...` & `/aws/bedrock/...` | 90 days | KMS CMK |

### Verification Commands (Run from AWS CloudShell in VPC Mode)
```bash
# 1. Confirm Private DNS resolves AWS endpoints to 10.40.x.x (not public IPs)
nslookup bedrock-runtime.eu-west-1.amazonaws.com
nslookup bedrock-agentcore.eu-west-1.amazonaws.com

# 2. Confirm zero public internet egress
curl -I --max-time 3 https://example.com   # Must time out

# 3. Run full E2E security & guardrail checks via Internal ALB
export TDA_API_BASE_URL="https://<alb-dns-name>/api"
export TDA_BEARER_TOKEN="<signed-rs256-jwt>"
python3 tests/e2e_tda_smoke.py
```

---

## 10. Network Team Sign-Off Checklist

| # | Item Required from Network / Security Team | Terraform Variable |
| :-: | :--- | :--- |
| 1 | Approved `/16` VPC CIDR & two `/24` private subnet CIDRs (IPAM) | `vpc_cidr`, `private_subnet_cidrs` |
| 2 | Zscaler connector egress CIDR list for `sg-alb` inbound `443` | `access_allowed_cidrs` |
| 3 | Private DNS `A`/Alias record for application hostname → Internal ALB | External DNS |
| 4 | ACM TLS certificate ARN in `eu-west-1` for application hostname | `acm_certificate_arn` |
| 5 | Entra ID tenant/app registration (`iss`, `aud`, internal/cached JWKS) | `entra_issuer`, `entra_audience`, `entra_jwks_url` |
