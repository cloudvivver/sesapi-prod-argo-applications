#!/usr/bin/env bash
# Cria/atualiza policy + role IRSA cuidar-sigtap-s3 (conta SESAPI 961341521437).
# Uso (com credenciais da conta SESAPI, região sa-east-1):
#   ./shared-storage/setup-sigtap-irsa.sh
set -euo pipefail

ACCOUNT_ID="${ACCOUNT_ID:-961341521437}"
CLUSTER_NAME="${CLUSTER_NAME:-prod-viver}"
REGION="${AWS_DEFAULT_REGION:-sa-east-1}"
POLICY_NAME="CuidarSigtapS3"
ROLE_NAME="cuidar-sigtap-s3"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
POLICY_FILE="${ROOT}/shared-storage/sigtap-s3-policy.json"

export AWS_DEFAULT_REGION="$REGION"

echo "==> Conta / caller"
aws sts get-caller-identity

OIDC_ISSUER=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
  --query "cluster.identity.oidc.issuer" --output text)
OIDC_ID="${OIDC_ISSUER#https://}"
echo "==> OIDC: $OIDC_ID"

POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"
if aws iam get-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1; then
  echo "==> Policy existe — criando nova versão"
  aws iam create-policy-version \
    --policy-arn "$POLICY_ARN" \
    --policy-document "file://${POLICY_FILE}" \
    --set-as-default >/dev/null
else
  echo "==> Criando policy ${POLICY_NAME}"
  aws iam create-policy \
    --policy-name "$POLICY_NAME" \
    --policy-document "file://${POLICY_FILE}" >/dev/null
fi

TRUST_FILE=$(mktemp)
trap 'rm -f "$TRUST_FILE"' EXIT
cat > "$TRUST_FILE" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_ID}"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringLike": {
        "${OIDC_ID}:sub": "system:serviceaccount:*:cuidar-sigtap-sa",
        "${OIDC_ID}:aud": "sts.amazonaws.com"
      }
    }
  }]
}
EOF

ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  echo "==> Role existe — atualizando trust"
  aws iam update-assume-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-document "file://${TRUST_FILE}"
else
  echo "==> Criando role ${ROLE_NAME}"
  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "file://${TRUST_FILE}" >/dev/null
fi

aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY_ARN" 2>/dev/null || true

echo "==> Pronto"
echo "ROLE_ARN=$ROLE_ARN"
echo "Anote a SA: cuidar-sigtap-sa com eks.amazonaws.com/role-arn: $ROLE_ARN"
