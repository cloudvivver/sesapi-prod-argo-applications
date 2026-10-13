# Jobs de cópia para o S3 (Mountpoint CSI)

Copiam os arquivos de um tenant para o PVC `s3-storage-pvc` (`s3://cuidar-storage/compartilhado/<DATABASE_PROD>/`) **antes** de sincronizar os Deployments do tenant. Contexto: [../S3-MOUNTPOINT-CSI.md](../S3-MOUNTPOINT-CSI.md).

| Arquivo | Função |
|---------|--------|
| `run-migracao.sh` | Lê namespace/`DATABASE_PROD` do `env-configmap.yaml` (e o PVC EFS do `pvc.yaml`), renderiza e roda o Job |
| `copiar-para-s3.sh` | Cópia com `cat > destino` (sem rename/chmod — o Mountpoint não suporta), não sobrescreve, confere nome+tamanho no fim |
| `mapear-minio.sh` | Converte o layout de chaves do SDK (`prd/<kind>/<tenant>/`, `saude/<tenant>/<modulo>/`) para o layout de filesystem |
| `migracao-efs-para-s3.yaml` | Job: PVC EFS (read-only) → PVC S3 |
| `migracao-minio-para-s3.yaml` | Job: `mc mirror` do MinIO para `emptyDir` → mapeia → PVC S3 |

## Uso

```bash
cd /home/cristiano/projetos/saude/k8s
DIR=curimata

kubectl apply -f $DIR/s3-storage-pv-pvc.yaml
./shared-storage/jobs/run-migracao.sh $DIR efs              # revisar o YAML
./shared-storage/jobs/run-migracao.sh $DIR efs --apply      # executar
```

Tenants que estavam no MinIO (`saude-homolog`, `bomjesus`): rodar **primeiro** `minio` (dados atuais) e **depois** `efs` (legado anterior ao MinIO). Como a cópia não sobrescreve, o que veio do MinIO prevalece.

```bash
./shared-storage/jobs/run-migracao.sh saude-homolog minio --apply
./shared-storage/jobs/run-migracao.sh saude-homolog efs --apply
```

`dev` não tem PVC EFS nem MinIO: não precisa de Job (só aplicar o PV/PVC).

Os Jobs podem ser repetidos (idempotentes: só copiam o que falta). Para recopiar algo do zero, apagar o objeto no S3 antes (`aws s3 rm`).

## Conferência

```bash
DB=$(awk '/^  DATABASE_PROD:/ {print $2; exit}' $DIR/env-configmap.yaml)
aws s3 ls s3://cuidar-storage/compartilhado/$DB/ --recursive --summarize | tail -3
```
