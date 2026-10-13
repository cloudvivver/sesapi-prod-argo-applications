# Solicitação à Infra — Policy do Mountpoint S3 CSI (Cuidar)

**Projeto:** SESAPI / Cuidar (EKS `prod-viver` / `sesapi-prod-viver`)  
**Data:** 13 de outubro de 2026  
**Solicitante:** Equipe Vivver / Cuidar  
**Referência:** chamado S3 — instalação do "Mountpoint para o Amazon S3 CSI driver" (concluído pela infra)  
**Status:** Aguardando retorno da infra (não bloqueante). Em 13/10/2026 a Vivver validou no `saude-homolog` leitura, escrita, sobrescrita e remoção em `compartilhado/saude_devel_pi/` via driver — a policy já cobre o prefixo. Falta confirmar o **escopo** (seção 2.3).

---

## 1. Contexto

A infra instalou o driver `s3.csi.aws.com` (v2.8.0) com credenciais **no nível do driver**:

| Item | Valor |
|------|-------|
| ServiceAccount | `kube-system/s3-csi-driver-sa` |
| Role | `arn:aws:iam::961341521437:role/AmazonEKS_S3_CSI_DriverRole` |
| Policy | `arn:aws:iam::961341521437:policy/amzn-s3-cuidar-storage` |
| Bucket | `cuidar-storage` (SSE-S3 / AES256, sem bucket policy) |
| Teste | PV `s3-pv` (`prefix teste-pod/`) no pod `default/s3-app` — OK |

Com isso, a Vivver vai **abandonar o pedido de IRSA por aplicação** ([SOLICITACAO-IRSA-SIGTAP-S3.md](./SOLICITACAO-IRSA-SIGTAP-S3.md)) e montar o bucket via PV/PVC estático em cada tenant. Desenho completo: [shared-storage/S3-MOUNTPOINT-CSI.md](./shared-storage/S3-MOUNTPOINT-CSI.md).

Prefixo de objetos que os tenants vão usar:

```text
s3://cuidar-storage/compartilhado/<DATABASE_PROD>/...
```

---

## 2. O que precisamos

### 2.1 JSON da policy `amzn-s3-cuidar-storage`

O SSO da equipe (`SESAPI-ECRFullAccess`) não tem `iam:GetPolicy`/`iam:GetPolicyVersion`. Favor enviar o documento da versão default ou executar:

```bash
POLICY_ARN=arn:aws:iam::961341521437:policy/amzn-s3-cuidar-storage
VER=$(aws iam get-policy --policy-arn $POLICY_ARN --query Policy.DefaultVersionId --output text)
aws iam get-policy-version --policy-arn $POLICY_ARN --version-id $VER --query PolicyVersion.Document
```

### 2.2 Permissões mínimas exigidas pelo Mountpoint

Confirmar (ou ajustar) que a policy cobre:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "MountpointListBucket",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::cuidar-storage"
    },
    {
      "Sid": "MountpointObjectRW",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:AbortMultipartUpload",
        "s3:DeleteObject"
      ],
      "Resource": [
        "arn:aws:s3:::cuidar-storage/compartilhado/*",
        "arn:aws:s3:::cuidar-storage/teste-pod/*"
      ]
    }
  ]
}
```

- `s3:DeleteObject` é necessário porque os PVs usam `allow-delete` (limpeza de importações SIGTAP/SIA, substituição de ZIP do e-SUS).
- Não é necessário KMS (bucket em SSE-S3).

### 2.3 Escopo da role do driver (segurança)

Como a credencial é do **driver**, qualquer PV `s3.csi.aws.com` criado no cluster usa a mesma role. O bucket `cuidar-storage` também guarda `production/`, `dossies/`, `backups/`, `employee-photos/`, `fotos_cadastrais/`. Recomendamos que a policy fique **restrita a `compartilhado/*` (e `teste-pod/*` enquanto o teste existir)**, e não ao bucket inteiro.

---

## 3. Retorno esperado

1. JSON atual da policy `amzn-s3-cuidar-storage`.
2. Confirmação de que `compartilhado/*` está coberto com Get/Put/Delete/AbortMultipartUpload.
3. (Opcional) Remover o pod/PV de teste `default/s3-app` + `s3-pv`/`s3-pvc` após nosso piloto em `saude-homolog`.

Com isso a Vivver aplica o PV/PVC do `saude-homolog`, roda a migração MinIO → S3 e valida importação SIGTAP/SIA e exportação e-SUS.
