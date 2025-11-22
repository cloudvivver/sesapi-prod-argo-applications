# Setup S3 Cache para C-TV

Este guia descreve como configurar cache híbrido (memória + S3) para o C-TV com IRSA (IAM Roles for Service Accounts).

## 📋 Pré-requisitos

- Cluster EKS configurado
- AWS CLI instalado e configurado
- kubectl configurado
- eksctl instalado (recomendado)

## 🪣 Passo 1: Criar Bucket S3

```bash
# Definir variáveis
AWS_REGION="sa-east-1"
AWS_ACCOUNT_ID="961341521437"
BUCKET_NAME="saude-ctv-audio-cache"
NAMESPACE="c-tv"

# Criar bucket S3 (se não existir)
aws s3 mb s3://${BUCKET_NAME} --region ${AWS_REGION}

# Bloquear acesso público (segurança)
aws s3api put-public-access-block \
  --bucket ${BUCKET_NAME} \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

# Habilitar versionamento (opcional, recomendado)
aws s3api put-bucket-versioning \
  --bucket ${BUCKET_NAME} \
  --versioning-configuration Status=Enabled

# Habilitar criptografia padrão (SSE-S3)
aws s3api put-bucket-encryption \
  --bucket ${BUCKET_NAME} \
  --server-side-encryption-configuration '{
    "Rules": [
      {
        "ApplyServerSideEncryptionByDefault": {
          "SSEAlgorithm": "AES256"
        },
        "BucketKeyEnabled": true
      }
    ]
  }'
```

## ⏰ Passo 2: Configurar Lifecycle Rules (Limpeza Automática)

```bash
# Criar lifecycle policy para expirar objetos antigos
cat > lifecycle-policy.json <<EOF
{
  "Rules": [
    {
      "Id": "DeleteExpiredCacheObjects",
      "Status": "Enabled",
      "Filter": {
        "Prefix": "c-tv/cache/"
      },
      "Expiration": {
        "Days": 30
      },
      "NoncurrentVersionExpiration": {
        "NoncurrentDays": 7
      }
    }
  ]
}
EOF

# Aplicar lifecycle policy
aws s3api put-bucket-lifecycle-configuration \
  --bucket ${BUCKET_NAME} \
  --lifecycle-configuration file://lifecycle-policy.json

# Remover arquivo temporário
rm lifecycle-policy.json
```

## 🔐 Passo 3: Criar IAM Policy

```bash
# Criar IAM policy
aws iam create-policy \
  --policy-name c-tv-s3-cache-policy \
  --policy-document file://iam-policy-s3-cache.json

# Anotar o ARN da policy (será usado no próximo passo)
POLICY_ARN=$(aws iam list-policies \
  --query 'Policies[?PolicyName==`c-tv-s3-cache-policy`].Arn' \
  --output text)

echo "Policy ARN: ${POLICY_ARN}"
```

## 🎭 Passo 4: Criar IAM Role com IRSA

### Opção 1: Usando eksctl (Recomendado)

```bash
# Obter nome do cluster
CLUSTER_NAME=$(kubectl config current-context | cut -d'/' -f2)

# Criar service account com IRSA
eksctl create iamserviceaccount \
  --name c-tv-s3-cache \
  --namespace ${NAMESPACE} \
  --cluster ${CLUSTER_NAME} \
  --region ${AWS_REGION} \
  --attach-policy-arn ${POLICY_ARN} \
  --approve \
  --override-existing-serviceaccounts
```

### Opção 2: Manual (se eksctl não estiver disponível)

```bash
# Obter OIDC provider do cluster
OIDC_PROVIDER=$(aws eks describe-cluster \
  --name ${CLUSTER_NAME} \
  --region ${AWS_REGION} \
  --query "cluster.identity.oidc.issuer" \
  --output text | sed -e "s/^https:\/\///")

# Criar trust policy
cat > trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_PROVIDER}:sub": "system:serviceaccount:${NAMESPACE}:c-tv-s3-cache",
          "${OIDC_PROVIDER}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF

# Criar IAM role
aws iam create-role \
  --role-name c-tv-s3-cache-role \
  --assume-role-policy-document file://trust-policy.json

# Anexar policy à role
aws iam attach-role-policy \
  --role-name c-tv-s3-cache-role \
  --policy-arn ${POLICY_ARN}

# Anotar ARN da role
ROLE_ARN=$(aws iam get-role \
  --role-name c-tv-s3-cache-role \
  --query 'Role.Arn' \
  --output text)

echo "Role ARN: ${ROLE_ARN}"

# Atualizar serviceaccount-s3-cache.yaml com o ARN correto
sed -i "s|arn:aws:iam::.*:role/.*|${ROLE_ARN}|" serviceaccount-s3-cache.yaml

# Aplicar service account
kubectl apply -f serviceaccount-s3-cache.yaml

# Limpar arquivos temporários
rm trust-policy.json
```

## 🌐 Passo 5: Criar VPC Endpoint para S3 (Opcional mas Recomendado)

```bash
# Obter VPC ID do cluster
VPC_ID=$(aws eks describe-cluster \
  --name ${CLUSTER_NAME} \
  --region ${AWS_REGION} \
  --query "cluster.resourcesVpcConfig.vpcId" \
  --output text)

# Obter route tables da VPC
ROUTE_TABLE_IDS=$(aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query "RouteTables[].RouteTableId" \
  --output text)

# Criar VPC endpoint para S3 (Gateway Endpoint)
aws ec2 create-vpc-endpoint \
  --vpc-id ${VPC_ID} \
  --service-name com.amazonaws.${AWS_REGION}.s3 \
  --route-table-ids ${ROUTE_TABLE_IDS}

echo "VPC Endpoint criado para S3"
```

**Benefícios do VPC Endpoint:**
- Tráfego S3 não sai para internet
- Menor latência
- Sem custo de NAT Gateway para S3
- Mais seguro

## ⚙️ Passo 6: Atualizar ConfigMap

```bash
# Aplicar ConfigMap atualizado com variáveis S3
kubectl apply -f env-configmap.yaml

# Verificar
kubectl get configmap env -n c-tv -o yaml
```

## 🚀 Passo 7: Atualizar Deployment

Atualizar `web-deployment.yaml` para usar o novo service account:

```yaml
spec:
  template:
    spec:
      serviceAccountName: c-tv-s3-cache  # Adicionar esta linha
      containers:
      - name: c-tv
        # ... resto da configuração
```

Aplicar deployment:

```bash
kubectl apply -f web-deployment.yaml
```

## ✅ Passo 8: Verificar Configuração

### Verificar Service Account

```bash
# Ver service account
kubectl get sa c-tv-s3-cache -n c-tv -o yaml

# Verificar anotação IRSA
kubectl get sa c-tv-s3-cache -n c-tv \
  -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'
```

### Verificar Pods

```bash
# Ver pods
kubectl get pods -n c-tv

# Verificar variáveis de ambiente AWS no pod
kubectl exec -it deployment/web -n c-tv -- env | grep AWS

# Deve mostrar:
# AWS_ROLE_ARN=arn:aws:iam::961341521437:role/c-tv-s3-cache-role
# AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/secrets/eks.amazonaws.com/serviceaccount/token
```

### Testar Acesso S3

```bash
# Port-forward para testar
kubectl port-forward svc/web-service 8080:8080 -n c-tv

# Em outro terminal, testar pré-aquecimento
curl -X POST "http://localhost:8080/prewarm?key=API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"text": "Teste de cache S3"}'

# Aguardar alguns segundos e verificar logs
kubectl logs -f deployment/web -n c-tv | grep -i s3

# Logs esperados:
# [S3Cache] Inicializado com bucket=saude-ctv-audio-cache...
# [HybridCache] ✅ Salvo em S3: 7fa8283e... (12345 bytes)
```

### Verificar Objetos no S3

```bash
# Listar objetos no bucket
aws s3 ls s3://${BUCKET_NAME}/c-tv/cache/ --recursive

# Ver detalhes de um objeto
aws s3api head-object \
  --bucket ${BUCKET_NAME} \
  --key c-tv/cache/7fa8283e3dd4c0e8610d3288b7a0a970.mp3
```

## 📊 Monitoramento

### CloudWatch Metrics (Opcional)

Você pode habilitar métricas do S3:

```bash
# Habilitar métricas de request no S3
aws s3api put-bucket-metrics-configuration \
  --bucket ${BUCKET_NAME} \
  --id c-tv-cache-metrics \
  --metrics-configuration '{
    "Id": "c-tv-cache-metrics",
    "Filter": {
      "Prefix": "c-tv/cache/"
    }
  }'
```

### Ver Estatísticas de Cache

```bash
# Endpoint de estatísticas (a ser implementado)
curl http://localhost:8080/cache/stats
```

## 🔧 Troubleshooting

### Erro: "AccessDenied" ao acessar S3

**Problema**: Pod não consegue acessar S3

**Soluções**:

1. Verificar se service account está corretamente anotado:
```bash
kubectl describe sa c-tv-s3-cache -n c-tv
```

2. Verificar se role IAM tem trust policy correta:
```bash
aws iam get-role --role-name c-tv-s3-cache-role --query 'Role.AssumeRolePolicyDocument'
```

3. Verificar se pod está usando o service account correto:
```bash
kubectl get pod <pod-name> -n c-tv -o jsonpath='{.spec.serviceAccountName}'
```

4. Verificar logs do pod:
```bash
kubectl logs deployment/web -n c-tv | grep -i "s3\|aws"
```

### Erro: "NoSuchBucket"

**Problema**: Bucket não existe ou nome incorreto

**Solução**:
```bash
# Verificar se bucket existe
aws s3 ls s3://${BUCKET_NAME}

# Verificar variável de ambiente no pod
kubectl exec -it deployment/web -n c-tv -- env | grep S3_CACHE_BUCKET
```

### Performance Issues

**Problema**: Cache S3 está lento

**Soluções**:

1. Verificar se VPC Endpoint está configurado:
```bash
aws ec2 describe-vpc-endpoints \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query "VpcEndpoints[?ServiceName=='com.amazonaws.${AWS_REGION}.s3']"
```

2. Aumentar tamanho do cache em memória no ConfigMap:
```yaml
CACHE_MEMORY_MAX_MB: "1024"  # 1GB
```

3. Verificar métricas de latência no CloudWatch

## 🔐 Segurança

### Checklist de Segurança

- ✅ Block Public Access habilitado no bucket
- ✅ Criptografia SSE-S3 habilitada
- ✅ IAM policy com princípio de menor privilégio
- ✅ IRSA configurado (não usar credenciais hardcoded)
- ✅ VPC Endpoint configurado (tráfego privado)
- ✅ Versionamento habilitado (proteção contra deleção acidental)
- ✅ Lifecycle rules configuradas (limpeza automática)
- ✅ Nenhum nome de paciente em chaves S3 (apenas hashes)

### LGPD Compliance

- ✅ Dados armazenados: apenas áudio MP3 (não contém metadados pessoais nas keys)
- ✅ Nomes de pacientes: apenas no conteúdo binário do MP3 (criptografado em descanso)
- ✅ Lifecycle: expiração automática após 30 dias
- ✅ Logs: não registrar nomes de pacientes
- ✅ Acesso: restrito via IAM policies

## 📝 Variáveis de Ambiente

Configuradas em `env-configmap.yaml`:

```yaml
# Cache Configuration
CACHE_BACKEND: "hybrid"  # "memory", "s3", ou "hybrid"

# S3 Cache Settings
S3_CACHE_ENABLED: "true"
S3_CACHE_BUCKET: "saude-ctv-audio-cache"
S3_CACHE_REGION: "sa-east-1"
S3_CACHE_PREFIX: "c-tv/cache"
S3_CACHE_TTL_HOURS: "720"  # 30 dias

# Memory Cache Settings
CACHE_MEMORY_ENABLED: "true"
CACHE_MEMORY_MAX_MB: "512"
CACHE_MEMORY_TTL_MINUTES: "60"
```

## 🎯 Resumo dos Comandos

```bash
# Setup completo
AWS_REGION="sa-east-1"
AWS_ACCOUNT_ID="961341521437"
BUCKET_NAME="saude-ctv-audio-cache"
NAMESPACE="c-tv"
CLUSTER_NAME=$(kubectl config current-context | cut -d'/' -f2)

# 1. Criar bucket
aws s3 mb s3://${BUCKET_NAME} --region ${AWS_REGION}
aws s3api put-public-access-block --bucket ${BUCKET_NAME} --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

# 2. Criar IAM policy
aws iam create-policy --policy-name c-tv-s3-cache-policy --policy-document file://iam-policy-s3-cache.json
POLICY_ARN=$(aws iam list-policies --query 'Policies[?PolicyName==`c-tv-s3-cache-policy`].Arn' --output text)

# 3. Criar IRSA com eksctl
eksctl create iamserviceaccount \
  --name c-tv-s3-cache \
  --namespace ${NAMESPACE} \
  --cluster ${CLUSTER_NAME} \
  --region ${AWS_REGION} \
  --attach-policy-arn ${POLICY_ARN} \
  --approve

# 4. Atualizar ConfigMap e Deployment
kubectl apply -f env-configmap.yaml
kubectl apply -f web-deployment.yaml

# 5. Verificar
kubectl get pods -n c-tv
kubectl logs -f deployment/web -n c-tv
```

## 📚 Referências

- [AWS EKS IRSA Documentation](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)
- [AWS S3 Lifecycle Configuration](https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lifecycle-mgmt.html)
- [AWS VPC Endpoints for S3](https://docs.aws.amazon.com/vpc/latest/privatelink/vpc-endpoints-s3.html)
