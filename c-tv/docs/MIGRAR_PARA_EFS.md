# Migração para EFS (ReadWriteMany)

Este guia explica como migrar de PVC ReadWriteOnce (gp2/gp3) para EFS ReadWriteMany quando a autorização for aprovada.

## Por que migrar para EFS?

**Situação atual (sem EFS):**
- ❌ Apenas **1 réplica** do backend (sem alta disponibilidade)
- ❌ Cache **não compartilhado** entre múltiplos pods
- ❌ Downtime durante atualizações (strategy: Recreate)
- ✅ Funciona sem aprovação adicional
- ✅ Mais barato (sem custo de EFS)

**Com EFS (ReadWriteMany):**
- ✅ **Múltiplas réplicas** do backend (3+)
- ✅ Cache **compartilhado** entre todos os pods
- ✅ **Zero downtime** em atualizações (RollingUpdate)
- ✅ Melhor performance distribuída
- ⚠️ Custo adicional do EFS
- ⚠️ Requer aprovação/configuração

## Pré-requisitos para EFS

1. **Aprovação** para criar EFS no ambiente AWS
2. **EFS File System** criado na mesma VPC do cluster EKS
3. **CSI Driver do EFS** instalado no cluster
4. **StorageClass** do EFS configurada

## Passos de Migração

### 1. Criar o EFS File System

Siga o guia em `EFS_SETUP.md` ou:

```bash
# Via AWS CLI
aws efs create-file-system \
  --performance-mode generalPurpose \
  --throughput-mode bursting \
  --encrypted \
  --tags Key=Name,Value=c-tv-audio-cache \
  --region sa-east-1

# Anotar o FileSystemId retornado
```

### 2. Instalar EFS CSI Driver (se não estiver)

```bash
kubectl apply -k "github.com/kubernetes-sigs/aws-efs-csi-driver/deploy/kubernetes/overlays/stable/?ref=release-1.7"

# Verificar
kubectl get pods -n kube-system | grep efs
```

### 3. Criar StorageClass do EFS

Já existe em `storageclass-efs.yaml`, mas ajuste o `fileSystemId`:

```bash
# Editar o arquivo
vim storageclass-efs.yaml

# Aplicar
kubectl apply -f storageclass-efs.yaml
```

### 4. Fazer Backup do Cache Atual (Opcional)

Se quiser preservar áudios em cache:

```bash
# Criar um pod temporário para copiar dados
kubectl run -n c-tv backup-pod --image=busybox --rm -it -- sh

# Dentro do pod, copiar para um bucket S3 ou similar
```

### 5. Atualizar PVC para EFS

**Passo 5.1: Deletar PVC antigo**

```bash
# Primeiro, escalar deployments para 0
kubectl scale deployment/web -n c-tv --replicas=0
kubectl scale deployment/coqui-server -n c-tv --replicas=0

# Aguardar pods terminarem
kubectl get pods -n c-tv -w

# Deletar PVC antigo
kubectl delete pvc audio-cache-pvc -n c-tv
```

**Passo 5.2: Editar audio-cache-pvc.yaml**

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: audio-cache-pvc
  namespace: c-tv
spec:
  accessModes:
    - ReadWriteMany  # EFS suporta RWX
  resources:
    requests:
      storage: 10Gi
  storageClassName: efs-sc  # StorageClass do EFS
```

**Passo 5.3: Aplicar novo PVC**

```bash
kubectl apply -f audio-cache-pvc.yaml

# Verificar se foi criado com EFS
kubectl get pvc -n c-tv
kubectl describe pvc audio-cache-pvc -n c-tv
```

### 6. Atualizar Deployment do Backend

**Editar web-deployment.yaml:**

```yaml
spec:
  replicas: 3  # Aumentar para 3 réplicas
  strategy:
    type: RollingUpdate  # Voltar para RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
      maxSurge: 1
  minReadySeconds: 30
  # ...
  template:
    spec:
      # REMOVER: affinity (não precisa mais estar no mesmo nó)
      containers:
      # ...
```

**Aplicar:**

```bash
kubectl apply -f web-deployment.yaml

# Verificar rollout
kubectl rollout status deployment/web -n c-tv
```

### 7. Escalar Coqui Server de Volta

```bash
kubectl scale deployment/coqui-server -n c-tv --replicas=1

# Aguardar
kubectl get pods -n c-tv -w
```

### 8. Verificar Funcionamento

```bash
# Ver pods (deve ter 3 backends + 1 coqui)
kubectl get pods -n c-tv

# Testar TTS
curl -I https://c-tv.saude.pi.gov.br/health

# Verificar cache compartilhado
kubectl exec -n c-tv deployment/web -- ls -la /app/cache_audio
kubectl exec -n c-tv deployment/coqui-server -- ls -la /app/cache_audio
```

### 9. Testar Alta Disponibilidade

```bash
# Deletar um pod backend
kubectl delete pod -n c-tv -l app.kubernetes.io/component=web --field-selector=status.phase=Running | head -1

# Verificar que serviço continua funcionando (zero downtime)
curl -I https://c-tv.saude.pi.gov.br/health
```

## Arquivo de Configuração Completo (com EFS)

### audio-cache-pvc.yaml (com EFS)

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: audio-cache-pvc
  namespace: c-tv
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 10Gi
  storageClassName: efs-sc
```

### web-deployment.yaml (com EFS)

```yaml
spec:
  replicas: 3
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
      maxSurge: 1
  minReadySeconds: 30
  # ... (resto sem mudanças, SEM affinity)
```

## Rollback (se necessário)

Se encontrar problemas, voltar para RWO:

```bash
# 1. Escalar para 0
kubectl scale deployment/web -n c-tv --replicas=0
kubectl scale deployment/coqui-server -n c-tv --replicas=0

# 2. Deletar PVC EFS
kubectl delete pvc audio-cache-pvc -n c-tv

# 3. Reverter mudanças nos arquivos
git checkout audio-cache-pvc.yaml web-deployment.yaml

# 4. Aplicar
kubectl apply -f audio-cache-pvc.yaml
kubectl apply -f web-deployment.yaml

# 5. Verificar
kubectl get pods -n c-tv
```

## Comparação de Custos

### Sem EFS (gp2/gp3):
- **Storage**: ~$0.10/GB/mês (gp3)
- **10GB**: ~$1.00/mês
- **Total**: **~$1/mês**

### Com EFS:
- **Storage**: ~$0.30/GB/mês (EFS Standard)
- **10GB**: ~$3.00/mês
- **Total**: **~$3/mês**

**Diferença**: ~$2/mês adicional

## Quando Usar EFS?

Use EFS quando:
- ✅ Precisar de **alta disponibilidade** (múltiplas réplicas)
- ✅ Tráfego justificar **múltiplos pods** backend
- ✅ Precisar de **zero downtime** em deploys
- ✅ Custo adicional for aceitável

Fique com RWO quando:
- ✅ Ambiente de **staging/desenvolvimento**
- ✅ Tráfego baixo (1 pod suficiente)
- ✅ Minimizar custos for prioridade

## Checklist de Migração

- [ ] Aprovação para criar EFS obtida
- [ ] EFS File System criado
- [ ] EFS CSI Driver instalado
- [ ] StorageClass EFS configurada
- [ ] Backup do cache atual (se necessário)
- [ ] PVC deletado e recriado com EFS
- [ ] Deployment atualizado (3 réplicas, RollingUpdate)
- [ ] Pods funcionando normalmente
- [ ] Cache compartilhado verificado
- [ ] Alta disponibilidade testada
- [ ] Documentação atualizada

## Suporte

Se encontrar problemas durante a migração:
- Ver logs: `kubectl logs -n c-tv deployment/web`
- Ver eventos: `kubectl get events -n c-tv --sort-by='.lastTimestamp'`
- Descrever PVC: `kubectl describe pvc audio-cache-pvc -n c-tv`
- Verificar StorageClass: `kubectl get sc efs-sc`
