#!/usr/bin/env bash
# Bedrock Guardrail module (creates a copy of Foul_Language_Blocker unless GUARDRAIL_ID is pre-set)

deploy_guardrail() {
  GUARDRAIL_VERSION="${GUARDRAIL_VERSION:-DRAFT}"

  if [ -n "${GUARDRAIL_ID:-}" ]; then
    echo "=== 0. Reusing existing Bedrock Guardrail (${GUARDRAIL_ID}) ==="
    GUARDRAIL_MANAGED="false"
    return 0
  fi

  GUARDRAIL_MANAGED="true"
  local guardrail_name="${FULL_PREFIX}-guardrail-${SUFFIX}"
  echo "=== 0. Creating Bedrock Guardrail (${guardrail_name}) ==="

  cat > /tmp/guardrail-content.json <<'EOT'
{
  "filtersConfig": [
    {"type": "VIOLENCE", "inputStrength": "HIGH", "outputStrength": "HIGH", "inputModalities": ["TEXT"], "outputModalities": ["TEXT"], "inputAction": "BLOCK", "outputAction": "BLOCK"},
    {"type": "PROMPT_ATTACK", "inputStrength": "HIGH", "outputStrength": "NONE", "inputAction": "BLOCK"},
    {"type": "MISCONDUCT", "inputStrength": "HIGH", "outputStrength": "HIGH", "inputModalities": ["TEXT"], "outputModalities": ["TEXT"], "inputAction": "BLOCK", "outputAction": "BLOCK"},
    {"type": "HATE", "inputStrength": "HIGH", "outputStrength": "HIGH", "inputModalities": ["TEXT"], "outputModalities": ["TEXT"], "inputAction": "BLOCK", "outputAction": "BLOCK"},
    {"type": "SEXUAL", "inputStrength": "HIGH", "outputStrength": "HIGH", "inputModalities": ["TEXT"], "outputModalities": ["TEXT"], "inputAction": "BLOCK", "outputAction": "BLOCK"},
    {"type": "INSULTS", "inputStrength": "HIGH", "outputStrength": "HIGH", "inputModalities": ["TEXT"], "outputModalities": ["TEXT"], "inputAction": "BLOCK", "outputAction": "BLOCK"}
  ],
  "tierConfig": {"tierName": "CLASSIC"}
}
EOT

  cat > /tmp/guardrail-words.json <<'EOT'
{
  "wordsConfig": [
    {"text": "Poo", "inputAction": "BLOCK", "outputAction": "BLOCK", "inputEnabled": true, "outputEnabled": true}
  ],
  "managedWordListsConfig": [
    {"type": "PROFANITY", "inputAction": "BLOCK", "outputAction": "BLOCK", "inputEnabled": true, "outputEnabled": true}
  ]
}
EOT

  cat > /tmp/guardrail-pii.json <<'EOT'
{
  "piiEntitiesConfig": [
    {"type": "NAME", "action": "ANONYMIZE", "inputAction": "ANONYMIZE", "outputAction": "ANONYMIZE", "inputEnabled": true, "outputEnabled": true},
    {"type": "PHONE", "action": "ANONYMIZE", "inputAction": "ANONYMIZE", "outputAction": "ANONYMIZE", "inputEnabled": true, "outputEnabled": true},
    {"type": "EMAIL", "action": "ANONYMIZE", "inputAction": "ANONYMIZE", "outputAction": "ANONYMIZE", "inputEnabled": true, "outputEnabled": true},
    {"type": "ADDRESS", "action": "ANONYMIZE", "inputAction": "ANONYMIZE", "outputAction": "ANONYMIZE", "inputEnabled": true, "outputEnabled": true},
    {"type": "AGE", "action": "ANONYMIZE", "inputAction": "ANONYMIZE", "outputAction": "ANONYMIZE", "inputEnabled": true, "outputEnabled": true},
    {"type": "USERNAME", "action": "ANONYMIZE", "inputAction": "ANONYMIZE", "outputAction": "ANONYMIZE", "inputEnabled": true, "outputEnabled": true},
    {"type": "PASSWORD", "action": "ANONYMIZE", "inputAction": "ANONYMIZE", "outputAction": "ANONYMIZE", "inputEnabled": true, "outputEnabled": true},
    {"type": "DRIVER_ID", "action": "ANONYMIZE", "inputAction": "ANONYMIZE", "outputAction": "ANONYMIZE", "inputEnabled": true, "outputEnabled": true},
    {"type": "LICENSE_PLATE", "action": "ANONYMIZE", "inputAction": "ANONYMIZE", "outputAction": "ANONYMIZE", "inputEnabled": true, "outputEnabled": true},
    {"type": "VEHICLE_IDENTIFICATION_NUMBER", "action": "ANONYMIZE", "inputAction": "ANONYMIZE", "outputAction": "ANONYMIZE", "inputEnabled": true, "outputEnabled": true},
    {"type": "CREDIT_DEBIT_CARD_CVV", "action": "ANONYMIZE", "inputAction": "ANONYMIZE", "outputAction": "ANONYMIZE", "inputEnabled": true, "outputEnabled": true},
    {"type": "CREDIT_DEBIT_CARD_EXPIRY", "action": "ANONYMIZE", "inputAction": "ANONYMIZE", "outputAction": "ANONYMIZE", "inputEnabled": true, "outputEnabled": true},
    {"type": "CREDIT_DEBIT_CARD_NUMBER", "action": "ANONYMIZE", "inputAction": "ANONYMIZE", "outputAction": "ANONYMIZE", "inputEnabled": true, "outputEnabled": true},
    {"type": "PIN", "action": "ANONYMIZE", "inputAction": "ANONYMIZE", "outputAction": "ANONYMIZE", "inputEnabled": true, "outputEnabled": true},
    {"type": "INTERNATIONAL_BANK_ACCOUNT_NUMBER", "action": "ANONYMIZE", "inputAction": "ANONYMIZE", "outputAction": "ANONYMIZE", "inputEnabled": true, "outputEnabled": true},
    {"type": "SWIFT_CODE", "action": "ANONYMIZE", "inputAction": "ANONYMIZE", "outputAction": "ANONYMIZE", "inputEnabled": true, "outputEnabled": true},
    {"type": "IP_ADDRESS", "action": "ANONYMIZE", "inputAction": "ANONYMIZE", "outputAction": "ANONYMIZE", "inputEnabled": true, "outputEnabled": true},
    {"type": "MAC_ADDRESS", "action": "ANONYMIZE", "inputAction": "ANONYMIZE", "outputAction": "ANONYMIZE", "inputEnabled": true, "outputEnabled": true},
    {"type": "URL", "action": "ANONYMIZE", "inputAction": "ANONYMIZE", "outputAction": "ANONYMIZE", "inputEnabled": true, "outputEnabled": true},
    {"type": "AWS_ACCESS_KEY", "action": "ANONYMIZE", "inputAction": "ANONYMIZE", "outputAction": "ANONYMIZE", "inputEnabled": true, "outputEnabled": true},
    {"type": "AWS_SECRET_KEY", "action": "ANONYMIZE", "inputAction": "ANONYMIZE", "outputAction": "ANONYMIZE", "inputEnabled": true, "outputEnabled": true},
    {"type": "US_PASSPORT_NUMBER", "action": "ANONYMIZE", "inputAction": "ANONYMIZE", "outputAction": "ANONYMIZE", "inputEnabled": true, "outputEnabled": true},
    {"type": "US_SOCIAL_SECURITY_NUMBER", "action": "ANONYMIZE", "inputAction": "ANONYMIZE", "outputAction": "ANONYMIZE", "inputEnabled": true, "outputEnabled": true},
    {"type": "US_INDIVIDUAL_TAX_IDENTIFICATION_NUMBER", "action": "ANONYMIZE", "inputAction": "ANONYMIZE", "outputAction": "ANONYMIZE", "inputEnabled": true, "outputEnabled": true},
    {"type": "US_BANK_ACCOUNT_NUMBER", "action": "ANONYMIZE", "inputAction": "ANONYMIZE", "outputAction": "ANONYMIZE", "inputEnabled": true, "outputEnabled": true},
    {"type": "US_BANK_ROUTING_NUMBER", "action": "ANONYMIZE", "inputAction": "ANONYMIZE", "outputAction": "ANONYMIZE", "inputEnabled": true, "outputEnabled": true},
    {"type": "CA_HEALTH_NUMBER", "action": "ANONYMIZE", "inputAction": "ANONYMIZE", "outputAction": "ANONYMIZE", "inputEnabled": true, "outputEnabled": true},
    {"type": "CA_SOCIAL_INSURANCE_NUMBER", "action": "ANONYMIZE", "inputAction": "ANONYMIZE", "outputAction": "ANONYMIZE", "inputEnabled": true, "outputEnabled": true},
    {"type": "UK_UNIQUE_TAXPAYER_REFERENCE_NUMBER", "action": "ANONYMIZE", "inputAction": "ANONYMIZE", "outputAction": "ANONYMIZE", "inputEnabled": true, "outputEnabled": true},
    {"type": "UK_NATIONAL_INSURANCE_NUMBER", "action": "ANONYMIZE", "inputAction": "ANONYMIZE", "outputAction": "ANONYMIZE", "inputEnabled": true, "outputEnabled": true},
    {"type": "UK_NATIONAL_HEALTH_SERVICE_NUMBER", "action": "ANONYMIZE", "inputAction": "ANONYMIZE", "outputAction": "ANONYMIZE", "inputEnabled": true, "outputEnabled": true}
  ]
}
EOT

  # shellcheck disable=SC2046
  GUARDRAIL_ID=$(aws bedrock create-guardrail \
    --name "${guardrail_name}" \
    --description "Blocks all foul language" \
    --blocked-input-messaging "Sorry, the model cannot answer this question, please stop using foul language." \
    --blocked-outputs-messaging "Sorry, the model cannot answer this question, please stop using foul language." \
    --content-policy-config file:///tmp/guardrail-content.json \
    --word-policy-config file:///tmp/guardrail-words.json \
    --sensitive-information-policy-config file:///tmp/guardrail-pii.json \
    --tags $(tags_bedrock_kv) \
    --query 'guardrailId' --output text --region "${AWS_REGION}")
}

teardown_guardrail() {
  if [ "${GUARDRAIL_MANAGED:-true}" = "true" ] && [ -n "${GUARDRAIL_ID:-}" ]; then
    echo "Deleting Lab Guardrail (${GUARDRAIL_ID})..."
    aws bedrock delete-guardrail --guardrail-identifier "${GUARDRAIL_ID}" --region "${AWS_REGION}" || true
  else
    echo "Preserving pre-existing Guardrail (${GUARDRAIL_ID:-none})."
  fi
}
