#!/bin/bash
set -e

NAMESPACE="saude-auditoria-gateway"

echo "=========================================="
echo "Criando Secrets para Saúde Auditoria"
echo "Namespace: $NAMESPACE"
echo "=========================================="
echo

# Verificar se namespace existe
if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
  echo "❌ Namespace $NAMESPACE não existe. Criando..."
  kubectl create namespace "$NAMESPACE"
  echo "✅ Namespace criado"
  echo
fi

# 1. Gateway Shared Secret
echo "1️⃣  Criando secret do Gateway..."
echo -n "   Deseja gerar um novo shared-secret? (s/N): "
read -r generate_secret

if [[ "$generate_secret" =~ ^[Ss]$ ]]; then
  SHARED_SECRET=$(openssl rand -base64 32)
  echo "   ✅ Secret gerado automaticamente"
else
  echo -n "   Digite o shared-secret (ou Enter para gerar): "
  read -r SHARED_SECRET
  if [ -z "$SHARED_SECRET" ]; then
    SHARED_SECRET=$(openssl rand -base64 32)
    echo "   ✅ Secret gerado automaticamente"
  fi
fi

kubectl create secret generic saude-auditoria-gateway-secret \
  --namespace="$NAMESPACE" \
  --from-literal=shared-secret="$SHARED_SECRET" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "   ✅ Secret 'saude-auditoria-gateway-secret' criado/atualizado"
echo "   📋 Shared secret: $SHARED_SECRET"
echo

# 2. S3 Credentials
echo "2️⃣  Criando credentials do S3..."
echo -n "   AWS Access Key ID: "
read -r AWS_ACCESS_KEY_ID

echo -n "   AWS Secret Access Key: "
read -rs AWS_SECRET_ACCESS_KEY
echo

echo -n "   AWS Region [sa-east-1]: "
read -r AWS_REGION
AWS_REGION=${AWS_REGION:-sa-east-1}

kubectl create secret generic s3-credentials \
  --namespace="$NAMESPACE" \
  --from-literal=AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
  --from-literal=AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
  --from-literal=AWS_REGION="$AWS_REGION" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "   ✅ Secret 's3-credentials' criado/atualizado"
echo

# Resumo
echo "=========================================="
echo "✅ Secrets criados com sucesso!"
echo "=========================================="
echo
echo "Verificar:"
echo "  kubectl get secrets -n $NAMESPACE"
echo
echo "Próximos passos:"
echo "  1. Edite s3-configmap.yaml com o nome do bucket S3"
echo "  2. kubectl apply -f s3-configmap.yaml"
echo "  3. kubectl apply -f ."
echo

# Perguntar se quer salvar localmente
echo -n "Deseja salvar os secrets localmente (secret.yaml e s3-credentials.yaml)? (s/N): "
read -r save_local

if [[ "$save_local" =~ ^[Ss]$ ]]; then
  # Criar secret.yaml local
  cat > secret.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: saude-auditoria-gateway-secret
  namespace: saude-auditoria-gateway
type: Opaque
stringData:
  shared-secret: "$SHARED_SECRET"
EOF

  # Criar s3-credentials.yaml local
  cat > s3-credentials.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: s3-credentials
  namespace: saude-auditoria-gateway
type: Opaque
stringData:
  AWS_ACCESS_KEY_ID: "$AWS_ACCESS_KEY_ID"
  AWS_SECRET_ACCESS_KEY: "$AWS_SECRET_ACCESS_KEY"
  AWS_REGION: "$AWS_REGION"
EOF

  chmod 600 secret.yaml s3-credentials.yaml
  echo "   ✅ Secrets salvos localmente (secret.yaml, s3-credentials.yaml)"
  echo "   ⚠️  CUIDADO: Estes arquivos estão no .gitignore, NÃO commite!"
else
  echo "   ℹ️  Secrets criados apenas no Kubernetes"
fi
