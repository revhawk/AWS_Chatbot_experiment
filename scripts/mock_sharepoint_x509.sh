#!/usr/bin/env bash
# Generates a mock X.509 client certificate + private key and the AWS Secrets Manager JSON payload
# for SharePoint Online app-only authentication (Sites.Selected + SharePoint ACL preservation).
#
# Output is written to .build/sharepoint_x509/ (gitignored — private keys are never committed).
#
# Usage:
#   ./scripts/mock_sharepoint_x509.sh                                # Local dry-run mock (default)
#   ./scripts/mock_sharepoint_x509.sh --upload-secret <secret-arn>   # Upload payload to AWS Secrets Manager

set -euo pipefail

OUT_DIR="${OUT_DIR:-.build/sharepoint_x509}"
TENANT_ID="${SHAREPOINT_TENANT_ID:-00000000-0000-0000-0000-000000000001}"
CLIENT_ID="${SHAREPOINT_CLIENT_ID:-00000000-0000-0000-0000-000000000002}"
CERT_CN="${SHAREPOINT_CERT_CN:-bedrock-rag-sharepoint-connector}"
CERT_DAYS="${SHAREPOINT_CERT_DAYS:-365}"
PERMISSION_SCOPE="${SHAREPOINT_PERMISSION_SCOPE:-Sites.Selected}"
AWS_REGION="${AWS_REGION:-eu-west-1}"
UPLOAD_SECRET_ARN=""

while [ $# -gt 0 ]; do
  case "$1" in
    --upload-secret)
      UPLOAD_SECRET_ARN="${2:-}"
      shift 2
      ;;
    --out-dir)
      OUT_DIR="${2:-}"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [ "${PERMISSION_SCOPE}" != "Sites.Selected" ] && [ "${PERMISSION_SCOPE}" != "Sites.Read.All" ]; then
  echo "ERROR: SHAREPOINT_PERMISSION_SCOPE must be 'Sites.Selected' (recommended) or 'Sites.Read.All'." >&2
  exit 1
fi

mkdir -p "${OUT_DIR}"
chmod 700 "${OUT_DIR}"

KEY_FILE="${OUT_DIR}/sharepoint_connector.key"
CERT_FILE="${OUT_DIR}/sharepoint_connector.crt"
PAYLOAD_FILE="${OUT_DIR}/sharepoint_secret_payload.json"

echo "=== 1. Generating RSA-2048 X.509 Certificate for SharePoint App-Only Auth ==="
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "${KEY_FILE}" \
  -out "${CERT_FILE}" \
  -days "${CERT_DAYS}" \
  -subj "/CN=${CERT_CN}" >/dev/null 2>&1

chmod 600 "${KEY_FILE}"

THUMBPRINT=$(openssl x509 -in "${CERT_FILE}" -noout -fingerprint -sha1 | cut -d'=' -f2 | tr -d ':')
echo "  Certificate: ${CERT_FILE} (upload this public cert to Entra ID App Registration)"
echo "  Private Key: ${KEY_FILE} (keep in AWS Secrets Manager only)"
echo "  SHA-1 Thumbprint: ${THUMBPRINT}"

echo "=== 2. Building AWS Secrets Manager JSON Payload ==="
python3 - "${TENANT_ID}" "${CLIENT_ID}" "${CERT_FILE}" "${KEY_FILE}" "${THUMBPRINT}" "${PERMISSION_SCOPE}" "${PAYLOAD_FILE}" <<'PY'
import json
import sys
from pathlib import Path

tenant_id, client_id, cert_path, key_path, thumbprint, scope, out_path = sys.argv[1:]
payload = {
    "tenantId": tenant_id,
    "clientId": client_id,
    "certificate": Path(cert_path).read_text(encoding="utf-8"),
    "privateKey": Path(key_path).read_text(encoding="utf-8"),
    "thumbprint": thumbprint,
    "permissionScope": scope,
    "preserveAcls": True,
}
Path(out_path).write_text(json.dumps(payload, indent=2), encoding="utf-8")
PY
chmod 600 "${PAYLOAD_FILE}"
echo "  Payload written: ${PAYLOAD_FILE}"

if [ -n "${UPLOAD_SECRET_ARN}" ]; then
  echo "=== 3. Uploading X.509 Secret Payload to AWS Secrets Manager ==="
  aws secretsmanager put-secret-value \
    --no-cli-pager \
    --region "${AWS_REGION}" \
    --secret-id "${UPLOAD_SECRET_ARN}" \
    --secret-string "file://${PAYLOAD_FILE}" >/dev/null
  echo "  Uploaded to ${UPLOAD_SECRET_ARN}"
else
  echo "=== 3. Dry-Run Complete (no AWS calls made) ==="
  echo "  Next: upload ${CERT_FILE} to your Entra ID App Registration, then run:"
  echo "    ./scripts/mock_sharepoint_x509.sh --upload-secret <aws-secretsmanager-arn>"
fi
