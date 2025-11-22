# Setup EFS para Cache Compartilhado

Este guia mostra como configurar EFS (Elastic File System) para permitir que múltiplos pods do c-tv compartilhem o mesmo cache de áudio.

## Por que EFS?

### Comparação de Storage no AWS EKS

| Storage | AccessMode | Múltiplos Pods | Performance | Custo |
|---------|-----------|----------------|-------------|-------|
| **EBS (gp3)** | ReadWriteOnce (RWO) | ❌ Não (1 pod apenas) | Alta | $0.08/GB/mês |
| **EFS** | ReadWriteMany (RWX) | ✅ Sim (N pods) | Média | $0.30/GB/mês |

**EFS permite**:
- ✅ Cache compartilhado entre todos os pods
- ✅ Alta disponibilidade com múltiplas réplicas
- ✅ Escalonamento horizontal

## Pré-requisitos

✅ **EFS CSI Driver já está instalado no cluster** (verificado)

## Passo 1: Criar EFS FileSystem

### Opção A: Via Console AWS

1. Acesse **EFS Console**: https://console.aws.amazon.com/efs
2. Região: **sa-east-1** (São Paulo)
3. Clique em **Create file system**
4. Configure:
   - **Name**: `c-tv-cache`
   - **VPC**: Mesma VPC do cluster EKS `prod-viver`
   - **Availability and Durability**: Regional (recomendado)
   - **Performance mode**: General Purpose
   - **Throughput mode**: Bursting
   - **Encryption**: Enabled (padrão)

5. **Network**:
   - Selecione as **mesmas subnets privadas** do cluster EKS
   - Security Group: Criar ou usar existente que permita NFS (porta 2049)

6. Anote o **FileSystemId** (formato: `fs-0123456789abcdef0`)

### Opção B: Via AWS CLI

```bash
# 1. Obter VPC ID do cluster
VPC_ID=$(aws eks describe-cluster \
  --name prod-viver \
  --region sa-east-1 \
  --query 'cluster.resourcesVpcConfig.vpcId' \
  --output text)

# 2. Criar Security Group para EFS
SG_ID=$(aws ec2 create-security-group \
  --group-name c-tv-efs-sg \
  --description "Security group for C-TV EFS" \
  --vpc-id $VPC_ID \
  --region sa-east-1 \
  --output text)

# 3. Permitir tráfego NFS do cluster
CLUSTER_SG=$(aws eks describe-cluster \
  --name prod-viver \
  --region sa-east-1 \
  --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' \
  --output text)

aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID \
  --protocol tcp \
  --port 2049 \
  --source-group $CLUSTER_SG \
  --region sa-east-1

# 4. Criar EFS FileSystem
FS_ID=$(aws efs create-file-system \
  --region sa-east-1 \
  --performance-mode generalPurpose \
  --throughput-mode bursting \
  --encrypted \
  --tags Key=Name,Value=c-tv-cache Key=Project,Value=c-tv \
  --query 'FileSystemId' \
  --output text)

echo "FileSystemId: $FS_ID"

# 5. Obter subnets do cluster
SUBNET_IDS=$(aws eks describe-cluster \
  --name prod-viver \
  --region sa-east-1 \
  --query 'cluster.resourcesVpcConfig.subnetIds' \
  --output text)

# 6. Criar mount targets nas subnets
for SUBNET in $SUBNET_IDS; do
  aws efs create-mount-target \
    --file-system-id $FS_ID \
    --subnet-id $SUBNET \
    --security-groups $SG_ID \
    --region sa-east-1
done

# 7. Aguardar FileSystem ficar available
aws efs describe-file-systems \
  --file-system-id $FS_ID \
  --region sa-east-1 \
  --query 'FileSystems[0].LifeCycleState'
```

## Passo 2: Configurar IAM para EFS (IRSA)

O EFS CSI Driver precisa de permissões para criar Access Points.

### Criar IAM Policy

```bash
cat > efs-csi-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "elasticfilesystem:DescribeAccessPoints",
        "elasticfilesystem:DescribeFileSystems",
        "elasticfilesystem:DescribeMountTargets",
        "elasticfilesystem:CreateAccessPoint",
        "elasticfilesystem:DeleteAccessPoint"
      ],
      "Resource": "*"
    }
  ]
}
EOF

aws iam create-policy \
  --policy-name CTVEFSCSIDriverPolicy \
  --policy-document file://efs-csi-policy.json \
  --region sa-east-1
```

### Associar ao ServiceAccount do EFS CSI Driver

```bash
eksctl create iamserviceaccount \
  --cluster=prod-viver \
  --region=sa-east-1 \
  --namespace=kube-system \
  --name=efs-csi-controller-sa \
  --attach-policy-arn=arn:aws:iam::961341521437:policy/CTVEFSCSIDriverPolicy \
  --override-existing-serviceaccounts \
  --approve
```

## Passo 3: Atualizar StorageClass com FileSystemId

```bash
# Editar storageclass-efs.yaml
# Substituir fs-XXXXXXXX pelo FileSystemId real
vim /home/cristiano/projetos/saude/k8s/c-tv/storageclass-efs.yaml
```

**Exemplo**:
```yaml
parameters:
  fileSystemId: fs-0123456789abcdef0  # ← Substituir aqui
```

## Passo 4: Aplicar Manifests

```bash
# 1. Criar StorageClass
kubectl apply -f storageclass-efs.yaml

# 2. Verificar
kubectl get storageclass efs-sc

# 3. Criar namespace (se não existir)
kubectl apply -f namespace.yaml

# 4. Aplicar ConfigMap e PVC
kubectl apply -f env-configmap.yaml
kubectl apply -f audio-cache-pvc.yaml

# 5. Aguardar PVC ficar Bound
kubectl get pvc -n c-tv -w

# 6. Deploy da aplicação
kubectl apply -f web-deployment.yaml
kubectl apply -f web-service.yaml
kubectl apply -f web-ingress.yaml

# 7. Verificar pods (devem ser 3 réplicas)
kubectl get pods -n c-tv -w
```

## Passo 5: Verificar Cache Compartilhado

```bash
# 1. Fazer uma requisição de TTS
curl -X POST https://c-tv.saude.pi.gov.br/speak \
  -H "Content-Type: application/json" \
  -d '{"text":"Teste de cache compartilhado","voice":"Camila"}'

# 2. Verificar logs de todos os pods
kubectl logs -n c-tv -l io.kompose.service=web --tail=20

# 3. Verificar conteúdo do cache em cada pod
for pod in $(kubectl get pods -n c-tv -l io.kompose.service=web -o name); do
  echo "=== $pod ==="
  kubectl exec -n c-tv $pod -- ls -lh /app/audio_cache
done

# Todos os pods devem ver os mesmos arquivos (cache compartilhado)
```

## Troubleshooting

### PVC fica Pending

```bash
# Verificar eventos
kubectl describe pvc audio-cache-pvc -n c-tv

# Verificar StorageClass
kubectl describe storageclass efs-sc

# Verificar logs do EFS CSI Controller
kubectl logs -n kube-system -l app=efs-csi-controller
```

**Problemas comuns**:
- FileSystemId incorreto no StorageClass
- Mount targets não criados nas subnets
- Security Group bloqueando porta 2049
- IRSA não configurado para EFS CSI Driver

### Pod não monta volume

```bash
# Verificar eventos do pod
kubectl describe pod -n c-tv <pod-name>

# Verificar logs do EFS CSI Node
kubectl logs -n kube-system -l app=efs-csi-node

# Testar conectividade NFS manualmente
kubectl run -it --rm debug --image=alpine --restart=Never -- sh
apk add nfs-utils
mount -t nfs4 -o nfsvers=4.1 <FS_ID>.efs.sa-east-1.amazonaws.com:/ /mnt
```

### Performance baixa

EFS tem throughput baseado em tamanho:
- **< 1 TB**: 50 MB/s baseline
- **1-10 TB**: 50-100 MB/s baseline

**Opções**:
1. **Elastic throughput** (recomendado): Ajusta automaticamente
2. **Provisioned throughput**: Define throughput fixo (custo adicional)

```bash
# Mudar para Elastic throughput
aws efs update-file-system \
  --file-system-id $FS_ID \
  --throughput-mode elastic \
  --region sa-east-1
```

## Migração de EBS para EFS

Se já tem dados no EBS:

```bash
# 1. Criar PVC temporário EBS
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: audio-cache-ebs-old
  namespace: c-tv
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
  storageClassName: gp3
EOF

# 2. Job de migração
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: cache-migration
  namespace: c-tv
spec:
  template:
    spec:
      containers:
      - name: rsync
        image: alpine:latest
        command: ["sh", "-c"]
        args:
          - |
            apk add rsync
            rsync -av /old-cache/ /new-cache/
        volumeMounts:
        - name: old-cache
          mountPath: /old-cache
        - name: new-cache
          mountPath: /new-cache
      volumes:
      - name: old-cache
        persistentVolumeClaim:
          claimName: audio-cache-ebs-old
      - name: new-cache
        persistentVolumeClaim:
          claimName: audio-cache-pvc
      restartPolicy: OnFailure
EOF

# 3. Aguardar migração
kubectl wait --for=condition=complete job/cache-migration -n c-tv --timeout=300s

# 4. Deletar PVC antigo
kubectl delete pvc audio-cache-ebs-old -n c-tv
```

## Custos Estimados

### EFS Standard

- **Storage**: $0.30/GB/mês
- **Requests**:
  - Read: $0.01/GB
  - Write: $0.06/GB

**Exemplo com 10 GB de cache**:
- Storage: 10 GB × $0.30 = **$3/mês**
- Requests (estimado): **$1-2/mês**
- **Total**: ~$5/mês

### Otimização de Custos

1. **EFS Infrequent Access (IA)**:
   - Storage: $0.043/GB/mês (85% mais barato)
   - Lifecycle policy: Move arquivos não acessados há 30 dias

```bash
aws efs put-lifecycle-configuration \
  --file-system-id $FS_ID \
  --lifecycle-policies TransitionToIA=AFTER_30_DAYS \
  --region sa-east-1
```

2. **Intelligent-Tiering**: Automático, sem custo adicional

## Referências

- **EFS CSI Driver**: https://github.com/kubernetes-sigs/aws-efs-csi-driver
- **EFS Best Practices**: https://docs.aws.amazon.com/efs/latest/ug/performance.html
- **IRSA**: https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html
