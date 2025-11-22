# C-TV - Text-to-Speech Service

Serviço de síntese de voz (TTS) usando AWS Polly no Kubernetes (EKS).

## Informações do Deploy

- **URL**: https://c-tv.saude.pi.gov.br
- **Namespace**: c-tv
- **Imagem**: 961341521437.dkr.ecr.sa-east-1.amazonaws.com/c-tv:coqui
- **TTS Provider**: AWS Polly
- **Região AWS**: sa-east-1 (São Paulo)
- **Voz padrão**: Camila (pt-BR)

## Arquitetura

```
Internet → NGINX Ingress → Service (web-service:80) → Pods (3x c-tv:8080)
                              ↓
                     EFS Volume (audio-cache compartilhado)
```

## Pré-requisitos

1. **DNS configurado**: Apontar `c-tv.saude.pi.gov.br` para o LoadBalancer do Ingress
2. **IRSA configurado**: ServiceAccount com permissões para AWS Polly (ver AWS_POLLY_RESUMO.md)
3. **Cert-manager**: Instalado para TLS/HTTPS automático

## Deploy

### 1. Criar namespace e recursos base

```bash
kubectl apply -f namespace.yaml
kubectl apply -f env-configmap.yaml
```

### 2. Criar EFS FileSystem e configurar StorageClass

**IMPORTANTE**: Antes de continuar, você precisa criar um EFS FileSystem. Siga o guia completo em `EFS_SETUP.md`.

```bash
# 1. Criar EFS FileSystem (ver EFS_SETUP.md)
# 2. Atualizar storageclass-efs.yaml com o FileSystemId
# 3. Aplicar StorageClass
kubectl apply -f storageclass-efs.yaml

# 4. Criar PVC
kubectl apply -f audio-cache-pvc.yaml

# 5. Verificar
kubectl get pvc -n c-tv
```

**Benefícios do EFS**:
- ✅ Cache compartilhado entre todos os pods (3 réplicas)
- ✅ ReadWriteMany (RWX) - múltiplos pods simultâneos
- ✅ Alta disponibilidade e escalabilidade

### 3. Configurar IRSA para AWS Polly

Aguardar infraestrutura criar IAM Role conforme `SOLICITACAO_IRSA_POLLY.md` e atualizar ServiceAccount.

### 4. Deploy da aplicação

```bash
kubectl apply -f web-deployment.yaml
kubectl apply -f web-service.yaml
kubectl apply -f web-ingress.yaml
```

### 5. Verificar

```bash
# Status dos pods
kubectl get pods -n c-tv -w

# Logs
kubectl logs -f -n c-tv -l io.kompose.service=web

# Ingress e certificado TLS
kubectl get ingress -n c-tv
kubectl get certificate -n c-tv
```

### 6. Testar

```bash
# Health check
curl https://c-tv.saude.pi.gov.br/health

# Síntese de voz
curl -X POST https://c-tv.saude.pi.gov.br/speak \
  -H "Content-Type: application/json" \
  -d '{"text":"Teste do C-TV com AWS Polly","voice":"Camila"}'
```

## Storage (EFS)

### Configuração Atual

- **StorageClass**: `efs-sc` (EFS)
- **AccessMode**: ReadWriteMany (RWX)
- **Réplicas**: 3 pods compartilhando o mesmo cache
- **Capacidade**: 10 GB (elástica, pode crescer automaticamente)

### Por que EFS?

| Recurso | EBS (gp3) | EFS |
|---------|-----------|-----|
| Múltiplos Pods | ❌ Não (RWO) | ✅ Sim (RWX) |
| Cache Compartilhado | ❌ | ✅ |
| Alta Disponibilidade | ⚠️ (1 pod) | ✅ (N pods) |
| Custo/GB/mês | $0.08 | $0.30 |

**Ver `EFS_SETUP.md` para instruções completas de setup.**

## Monitoramento

- **Sentry**: https://sentry.bigdatasys.net/27
- **Logs**: `kubectl logs -f -n c-tv -l io.kompose.service=web`
- **Métricas**: Via AWS CloudWatch (região sa-east-1)

## Troubleshooting

### Pod não inicia

```bash
# Verificar eventos
kubectl describe pod -n c-tv -l io.kompose.service=web

# Verificar IRSA
kubectl describe sa -n c-tv
```

### Erro de acesso ao AWS Polly

- Verificar se ServiceAccount tem anotação `eks.amazonaws.com/role-arn`
- Verificar permissões da IAM Role
- Ver logs: `kubectl logs -n c-tv -l io.kompose.service=web`

### Certificado TLS não gerado

```bash
# Verificar cert-manager
kubectl get certificate -n c-tv
kubectl describe certificate c-tv-tls -n c-tv

# Verificar challenge
kubectl get challenges -n c-tv
```

## Configuração

Ver `env-configmap.yaml` para variáveis de ambiente:
- `TTS_PROVIDER`: "polly"
- `TTS_VOICE`: "Camila" (padrão)
- `AWS_REGION`: "sa-east-1"
- `CACHE_TTL_MINUTES`: "10"
- `CACHE_MAX_SIZE_MB`: "1024"

## Migração do Azure para AWS

**Arquivos de backup (não usar)**:
- `azure-tts-secret.yaml.backup` - Secret antigo do Azure TTS
- `audio-cache-pv.yaml.azure-backup` - PV antigo do Azure Files

**Mudanças principais**:
- TTS Provider: Microsoft Azure → AWS Polly
- Storage: Azure Files (RWX) → AWS EFS (RWX)
- Imagem: Azure ACR → AWS ECR
- Autenticação: Secret Key → IRSA
- Réplicas: 3 pods compartilhando cache via EFS

## Documentação Adicional

- **EFS Setup Guide**: `EFS_SETUP.md` ⭐ **LEIA PRIMEIRO**
- **AWS Polly Setup**: `/home/cristiano/projetos/saude/c-tv/AWS_POLLY_RESUMO.md`
- **IRSA Guide**: `/home/cristiano/projetos/saude/c-tv/SOLICITACAO_IRSA_POLLY.md`
- **Projeto**: `/home/cristiano/projetos/saude/c-tv/CLAUDE.md`

## Comandos Úteis

```bash
# Ver todos os recursos do c-tv
kubectl get all -n c-tv

# Escalar (EFS RWX permite múltiplas réplicas)
kubectl scale deployment web -n c-tv --replicas=5

# Verificar cache compartilhado em todos os pods
for pod in $(kubectl get pods -n c-tv -l io.kompose.service=web -o name); do
  echo "=== $pod ==="
  kubectl exec -n c-tv $pod -- ls -lh /app/audio_cache | head -5
done

# Rollout restart
kubectl rollout restart deployment/web -n c-tv

# Port-forward para debug local
kubectl port-forward -n c-tv svc/web-service 8080:80

# Deletar tudo
kubectl delete namespace c-tv
```

## Suporte

- **Desenvolvimento**: josmar_otonioni@bigdatahealth.com.br
- **Infraestrutura**: Solicitar via SOLICITACAO_IRSA_POLLY.md
