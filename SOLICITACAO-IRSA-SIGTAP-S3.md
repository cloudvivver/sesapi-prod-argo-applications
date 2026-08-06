# Solicitação à Infra — IRSA para S3 (SIGTAP / SIA — Cuidar)

**Projeto:** SESAPI / Cuidar (EKS `prod-viver` / `sesapi-prod-viver`)  
**Data:** 5 de agosto de 2026  
**Solicitante:** Equipe Vivver / Cuidar  
**Prioridade:** Alta (mitigação de hangs NFS/EFS nos nós; migração de storage da importação PRD)  
**Status:** Aguardando implementação AWS (IAM) — lado Kubernetes do homolog já preparado  

---

## 1. Objetivo

Habilitar acesso seguro ao bucket S3 **`cuidar-storage`** para os workloads do Cuidar no EKS, via **IRSA** (IAM Roles for Service Accounts), **sem Access Keys estáticas**.

O uso imediato é a importação **SIGTAP / SIA** (arquivos PRD), hoje em EFS (`/mnt/compartilhado/...`). A aplicação já possui backend dual (`SIGTAP_STORAGE=efs|s3`); em homolog a SA e os Deployments já apontam para a role abaixo — falta apenas a role/policy no IAM.

### Dados de referência

| Item | Valor |
|------|-------|
| Conta AWS | `961341521437` |
| Região | `sa-east-1` |
| Cluster EKS | `prod-viver` / `sesapi-prod-viver` |
| Bucket S3 | `cuidar-storage` |
| Prefixo de objetos | `prd/sigtap/<DATABASE_PROD>/` e `prd/sia/<DATABASE_PROD>/` |
| Policy IAM (nome sugerido) | `CuidarSigtapS3` |
| Role IAM (nome sugerido) | `cuidar-sigtap-s3` |
| ARN esperado da role | `arn:aws:iam::961341521437:role/cuidar-sigtap-s3` |
| ServiceAccount (K8s) | `cuidar-sigtap-sa` |
| Primeiro namespace | `saude-homolog` (piloto) |
| Demais tenants (fase 2) | municípios + `treinamento` / `apresentacao` (mesma SA name) |

Trust sugerido (uma role compartilhada para todos os tenants):

```text
system:serviceaccount:*:cuidar-sigtap-sa
```

---

## 2. Contexto / por que precisamos

1. Em 05/08/2026 o cluster teve **3 nós NotReady** com flood de `nfs: server 127.0.0.1 not responding` (cliente EFS/stunnel), contribuindo para evicção e falta de capacidade.
2. O EFS é montado pelos apps Cuidar principalmente para arquivos **PRD/SIGTAP/SIA**.
3. O código já grava/lê no S3 quando `SIGTAP_STORAGE=s3`, usando o SDK AWS e **IRSA** (sem keys no Secret).
4. Validação atual no pod homolog:
   - Rede até S3: OK  
   - `AWS_ROLE_ARN` / token IRSA injetados: OK  
   - `sts:AssumeRoleWithWebIdentity` → **AccessDenied** (role inexistente ou trust não criado)

**Obs.:** O pedido de IRSA da **Auditoria** (`s3-cuidar-storage-auditoria` / role `saude-auditoria-gateway-s3`) é **outro bucket e outro SA** — não substitui este.

---

## 3. Procedimentos do Administrador (AWS CLI)

Script pronto no repositório GitOps (se preferir):

```bash
# Repo: sesapi-prod-argo-applications
./shared-storage/setup-sigtap-irsa.sh
```

Policy JSON de referência: `shared-storage/sigtap-s3-policy.json`

### Passo 1 — Issuer OIDC do cluster

```bash
aws eks describe-cluster --name prod-viver --region sa-east-1 \
  --query "cluster.identity.oidc.issuer" --output text
# Se o nome do cluster for sesapi-prod-viver, use esse nome.
```

Remova o prefixo `https://` e grave em `OIDC_ID`. Confirme que o OIDC provider já existe em:

`arn:aws:iam::961341521437:oidc-provider/<OIDC_ID>`

### Passo 2 — Policy IAM

```bash
cat > policy-cuidar-sigtap-s3.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListBucket",
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:GetBucketLocation"
      ],
      "Resource": "arn:aws:s3:::cuidar-storage"
    },
    {
      "Sid": "ObjectRW",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject"
      ],
      "Resource": [
        "arn:aws:s3:::cuidar-storage/prd/sigtap/*",
        "arn:aws:s3:::cuidar-storage/prd/sia/*"
      ]
    }
  ]
}
EOF

aws iam create-policy \
  --policy-name CuidarSigtapS3 \
  --policy-document file://policy-cuidar-sigtap-s3.json

# ARN esperado:
# arn:aws:iam::961341521437:policy/CuidarSigtapS3
```

Se a policy já existir, criar nova versão com `--set-as-default`.

### Passo 3 — Role IAM + Trust (IRSA)

```bash
OIDC_ID=$(aws eks describe-cluster --name prod-viver --region sa-east-1 \
  --query "cluster.identity.oidc.issuer" --output text | sed 's#https://##')

cat > trust-cuidar-sigtap-s3.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::961341521437:oidc-provider/${OIDC_ID}"
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

aws iam create-role \
  --role-name cuidar-sigtap-s3 \
  --assume-role-policy-document file://trust-cuidar-sigtap-s3.json \
  --description "IRSA Cuidar SIGTAP/SIA -> s3://cuidar-storage/prd/"

aws iam attach-role-policy \
  --role-name cuidar-sigtap-s3 \
  --policy-arn arn:aws:iam::961341521437:policy/CuidarSigtapS3
```

### Passo 4 — Checklist admin (devolver à Vivver)

- [ ] Policy `CuidarSigtapS3` criada/atualizada  
- [ ] Role `cuidar-sigtap-s3` criada  
- [ ] Trust com OIDC do cluster e `sub` = `system:serviceaccount:*:cuidar-sigtap-sa`  
- [ ] Policy anexada à role  
- [ ] Confirmação do ARN: `arn:aws:iam::961341521437:role/cuidar-sigtap-s3`  
- [ ] (Opcional) Teste: `aws iam get-role --role-name cuidar-sigtap-s3`

---

## 4. Lado Kubernetes (já feito pela Vivver — só para ciência)

**Não é necessário o admin aplicar isto** se o ArgoCD estiver sincronizado. Incluído para alinhar a intenção.

### ServiceAccount (homolog — piloto)

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: cuidar-sigtap-sa
  namespace: saude-homolog
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::961341521437:role/cuidar-sigtap-s3
```

### Deployments

`webhomolog` e `sidekiq` em `saude-homolog` usam:

```yaml
spec:
  template:
    spec:
      serviceAccountName: cuidar-sigtap-sa
```

### ConfigMap (após IAM pronto)

```yaml
SIGTAP_STORAGE: "s3"          # hoje ainda "efs" até a role existir
SIGTAP_S3_BUCKET: "cuidar-storage"
SIGTAP_S3_PREFIX: "prd"
AWS_REGION: "sa-east-1"
```

A troca `efs` → `s3` será feita pela Vivver **depois** do retorno do ARN confirmado.

---

## 5. Validação (pós-implementação)

```bash
# 1) Pod assume a role?
kubectl exec -n saude-homolog deploy/webhomolog -c webhomolog -- \
  bundle exec ruby -e '
    require "aws-sdk-core"
    c = Aws::STS::Client.new(region: "sa-east-1")
    puts c.get_caller_identity.arn
  '

# Esperado: conter ...:assumed-role/cuidar-sigtap-s3/...

# 2) Put/Get de probe no prefixo SIGTAP
kubectl exec -n saude-homolog deploy/sidekiq -- \
  bundle exec rails runner '
    s = Prd::SigtapStorage.new(kind: "sigtap")
    # requer SIGTAP_STORAGE=s3
    k = s.write("probe-infra.txt", "ok")
    puts "key=#{k}"
    s.with_local_file(k) { |p| puts File.read(p) }
  '
```

---

## 6. Escopo e não-escopo

**No escopo**
- IAM Policy + Role IRSA para `cuidar-storage` / prefixos `prd/sigtap/*` e `prd/sia/*`
- Trust permitindo SA `cuidar-sigtap-sa` em qualquer namespace do cluster

**Fora do escopo (Vivver)**
- Rollout `SIGTAP_STORAGE=s3` nos municípios  
- Remoção posterior do mount EFS  
- IRSA da Auditoria (`s3-cuidar-storage-auditoria`) — ticket separado

---

## 7. Contato / retorno

Favor retornar:

1. Confirmação de criação (policy + role)  
2. ARN final da role (se diferente do sugerido)  
3. Qualquer restrição de bucket policy / SCP que bloqueie o acesso  

Com isso a Vivver ativa `SIGTAP_STORAGE=s3` no `saude-homolog` e valida a importação SIGTAP na UI.
