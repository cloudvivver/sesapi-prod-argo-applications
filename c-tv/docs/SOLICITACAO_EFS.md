# Solicitação: Criar EFS FileSystem para C-TV

## Objetivo
Criar um EFS FileSystem para cache compartilhado de áudio do serviço c-tv, permitindo múltiplas réplicas compartilharem o mesmo cache.

## Justificativa
- **Cache compartilhado**: Múltiplos pods (3 réplicas) precisam acessar o mesmo cache de áudio
- **Alta disponibilidade**: EFS permite ReadWriteMany (RWX), diferente do EBS que é ReadWriteOnce (RWO)
- **Economia**: Cache compartilhado reduz chamadas ao AWS Polly (custo de $4/1M caracteres)

## Informações do Ambiente

- **Cluster EKS**: prod-viver
- **Região**: sa-east-1
- **Account ID**: 961341521437
- **Namespace**: c-tv
- **Aplicação**: Text-to-Speech Service

## Especificações do EFS

```yaml
Name: c-tv-audio-cache
Região: sa-east-1
Performance Mode: General Purpose
Throughput Mode: Elastic (recomendado) ou Bursting
Encryption: Enabled
Lifecycle Policy: AFTER_30_DAYS → Infrequent Access (opcional, economiza 85%)
Capacity: Elástica (começa com ~10GB)
Tags:
  - Name: c-tv-audio-cache
  - Project: c-tv
  - Environment: production
  - ManagedBy: Infrastructure
```

## Rede (Network)

**VPC**: Mesma VPC do cluster EKS prod-viver

**Subnets**: Todas as subnets privadas do cluster (para alta disponibilidade)

**Security Group**: Criar novo ou usar existente com as regras:
```
Type: NFS
Protocol: TCP
Port: 2049
Source: Security Group do cluster EKS (ou CIDR da VPC)
```

## Script de Criação (AWS CLI)

Execute os comandos abaixo com uma conta que tenha permissões de:
- `elasticfilesystem:*`
- `ec2:DescribeSubnets`
- `ec2:CreateSecurityGroup`
- `ec2:AuthorizeSecurityGroupIngress`
- `eks:DescribeCluster`

### 1. Obter informações do cluster

```bash
# Cluster e VPC
CLUSTER_NAME="prod-viver"
REGION="sa-east-1"

VPC_ID=$(aws eks describe-cluster \
  --name $CLUSTER_NAME \
  --region $REGION \
  --query 'cluster.resourcesVpcConfig.vpcId' \
  --output text)

echo "VPC ID: $VPC_ID"

# Subnets do cluster
SUBNET_IDS=$(aws eks describe-cluster \
  --name $CLUSTER_NAME \
  --region $REGION \
  --query 'cluster.resourcesVpcConfig.subnetIds' \
  --output text)

echo "Subnet IDs: $SUBNET_IDS"

# Security Group do cluster
CLUSTER_SG=$(aws eks describe-cluster \
  --name $CLUSTER_NAME \
  --region $REGION \
  --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' \
  --output text)

echo "Cluster SG: $CLUSTER_SG"
```

### 2. Criar Security Group para EFS

```bash
# Criar SG
SG_ID=$(aws ec2 create-security-group \
  --group-name c-tv-efs-sg \
  --description "Security group for C-TV EFS audio cache" \
  --vpc-id $VPC_ID \
  --region $REGION \
  --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=c-tv-efs-sg},{Key=Project,Value=c-tv}]' \
  --output text)

echo "Security Group criado: $SG_ID"

# Permitir tráfego NFS do cluster
aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID \
  --protocol tcp \
  --port 2049 \
  --source-group $CLUSTER_SG \
  --region $REGION

echo "Regra NFS adicionada"
```

### 3. Criar EFS FileSystem

```bash
# Criar FileSystem
FS_ID=$(aws efs create-file-system \
  --region $REGION \
  --performance-mode generalPurpose \
  --throughput-mode elastic \
  --encrypted \
  --tags Key=Name,Value=c-tv-audio-cache Key=Project,Value=c-tv Key=Environment,Value=production \
  --query 'FileSystemId' \
  --output text)

echo "================================================================"
echo "EFS FileSystem criado: $FS_ID"
echo "================================================================"

# Opcional: Configurar lifecycle policy (move para IA após 30 dias - economiza 85%)
aws efs put-lifecycle-configuration \
  --file-system-id $FS_ID \
  --lifecycle-policies TransitionToIA=AFTER_30_DAYS \
  --region $REGION

echo "Lifecycle policy configurada (Infrequent Access após 30 dias)"
```

### 4. Criar Mount Targets nas Subnets

```bash
# Aguardar FileSystem ficar available
echo "Aguardando FileSystem ficar disponível..."
aws efs describe-file-systems \
  --file-system-id $FS_ID \
  --region $REGION \
  --query 'FileSystems[0].LifeCycleState' \
  --output text

# Criar mount target em cada subnet
for SUBNET in $SUBNET_IDS; do
  echo "Criando mount target na subnet $SUBNET..."
  MT_ID=$(aws efs create-mount-target \
    --file-system-id $FS_ID \
    --subnet-id $SUBNET \
    --security-groups $SG_ID \
    --region $REGION \
    --query 'MountTargetId' \
    --output text)
  echo "  Mount target criado: $MT_ID"
done

echo "Todos os mount targets criados!"
```

### 5. Verificar

```bash
# Status do FileSystem
aws efs describe-file-systems \
  --file-system-id $FS_ID \
  --region $REGION

# Mount targets
aws efs describe-mount-targets \
  --file-system-id $FS_ID \
  --region $REGION
```

### 6. **IMPORTANTE**: Informar o FileSystemId

Após a criação, **enviar o FileSystemId para o time de desenvolvimento**:

```
FileSystemId: fs-XXXXXXXXXXXXXXXXX
```

Este ID será usado no arquivo `storageclass-efs.yaml`.

## Configuração IRSA para EFS CSI Driver

O EFS CSI Driver precisa de permissões para criar Access Points dinamicamente.

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
        "elasticfilesystem:DeleteAccessPoint",
        "elasticfilesystem:TagResource"
      ],
      "Resource": "*"
    }
  ]
}
EOF

aws iam create-policy \
  --policy-name CTVEFSCSIDriverPolicy \
  --policy-document file://efs-csi-policy.json \
  --region $REGION
```

### Associar ao ServiceAccount do EFS CSI

```bash
eksctl create iamserviceaccount \
  --cluster=$CLUSTER_NAME \
  --region=$REGION \
  --namespace=kube-system \
  --name=efs-csi-controller-sa \
  --attach-policy-arn=arn:aws:iam::961341521437:policy/CTVEFSCSIDriverPolicy \
  --override-existing-serviceaccounts \
  --approve
```

## Após Criação

Informar ao time de desenvolvimento:

1. **FileSystemId**: `fs-XXXXXXXXXXXXXXXXX` (obrigatório)
2. **Security Group ID**: `sg-XXXXXXXXXXXXXXXXX` (para referência)
3. **Mount Targets IPs**: (opcional, para debugging)

## Custos Estimados

### EFS Standard
- **Storage**: $0.30/GB/mês × 10GB = **$3/mês**
- **Requests**: ~$1-2/mês (estimado)
- **Total**: ~**$5/mês**

### Com Lifecycle Policy (Infrequent Access)
- Storage > 30 dias: $0.043/GB/mês (85% mais barato)
- **Total estimado**: ~**$2-3/mês** (após 30 dias)

### Comparação com EBS
- **EBS gp3**: $0.08/GB/mês × 10GB = $0.80/mês
- **EFS**: $3/mês
- **Diferença**: +$2.20/mês

**Justificativa**: Cache compartilhado reduz chamadas ao Polly (economia >> $2/mês)

## Contato

**Solicitante**: josmar_otonioni@bigdatahealth.com.br
**Projeto**: C-TV (Text-to-Speech Service)
**Urgência**: Normal
**Prazo sugerido**: 2-3 dias úteis

---

## Anexos

- `EFS_SETUP.md` - Guia completo técnico
- `storageclass-efs.yaml` - StorageClass Kubernetes (precisa do FileSystemId)
- `audio-cache-pvc.yaml` - PersistentVolumeClaim
- `README.md` - Documentação do deploy

## Referências

- [AWS EFS User Guide](https://docs.aws.amazon.com/efs/latest/ug/)
- [EFS CSI Driver](https://github.com/kubernetes-sigs/aws-efs-csi-driver)
- [EKS Storage](https://docs.aws.amazon.com/eks/latest/userguide/storage.html)
