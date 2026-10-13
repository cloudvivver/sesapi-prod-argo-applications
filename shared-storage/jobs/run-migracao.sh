#!/usr/bin/env bash
# Renderiza e (com --apply) executa o Job de cópia para o PVC S3 (Mountpoint) de um tenant.
# Uso (na raiz do repo k8s):
#   ./shared-storage/jobs/run-migracao.sh <dir-do-tenant> efs|minio            # só imprime o YAML
#   ./shared-storage/jobs/run-migracao.sh <dir-do-tenant> efs|minio --apply    # aplica, espera e mostra logs
# Pré-requisito: <dir>/s3-storage-pv-pvc.yaml aplicado e PVC s3-storage-pvc Bound.
set -euo pipefail

DIR="${1:?dir do tenant (ex.: curimata)}"
ORIGEM="${2:?efs|minio}"
APPLY="${3:-}"
JOBS="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$JOBS/../.." && pwd)"
CM="$ROOT/$DIR/env-configmap.yaml"

campo() { tr -d '\r' < "$2" | awk -v k="^  $1:" '$0 ~ k {print $2; exit}'; }

NS=$(campo namespace "$CM")
DB=$(campo DATABASE_PROD "$CM")
[ -n "$NS" ] && [ -n "$DB" ] || { echo "Não achei namespace/DATABASE_PROD em $CM" >&2; exit 1; }

case "$ORIGEM" in
  efs)
    EFS_PVC=$(campo name "$ROOT/$DIR/pvc.yaml")
    TEMPLATE="$JOBS/migracao-efs-para-s3.yaml"
    JOB=migracao-s3-efs
    ;;
  minio)
    EFS_PVC=""
    TEMPLATE="$JOBS/migracao-minio-para-s3.yaml"
    JOB=migracao-s3-minio
    ;;
  *) echo "origem deve ser efs ou minio" >&2; exit 1 ;;
esac

render() {
  kubectl create configmap migracao-s3-scripts -n "$NS" \
    --from-file="$JOBS/copiar-para-s3.sh" --from-file="$JOBS/mapear-minio.sh" \
    --dry-run=client -o yaml
  echo "---"
  sed -e "s/__NAMESPACE__/$NS/g" -e "s/__DATABASE_PROD__/$DB/g" -e "s/__EFS_PVC__/$EFS_PVC/g" "$TEMPLATE"
}

echo "# tenant=$DIR namespace=$NS DATABASE_PROD=$DB origem=$ORIGEM ${EFS_PVC:+efs_pvc=$EFS_PVC}" >&2

if [ "$APPLY" != "--apply" ]; then
  render
  exit 0
fi

kubectl get pvc -n "$NS" s3-storage-pvc -o jsonpath='{.status.phase}' | grep -qx Bound \
  || { echo "PVC $NS/s3-storage-pvc não está Bound — aplique $DIR/s3-storage-pv-pvc.yaml antes" >&2; exit 1; }

kubectl delete job -n "$NS" "$JOB" --ignore-not-found
render | kubectl apply -f -
STATUS=""
for _ in $(seq 1 360); do
  STATUS=$(kubectl get job -n "$NS" "$JOB" \
    -o jsonpath='{range .status.conditions[?(@.status=="True")]}{.type}{"\n"}{end}' | grep -E '^(Complete|Failed)$' || true)
  [ -n "$STATUS" ] && break
  sleep 5
done
kubectl logs -n "$NS" "job/$JOB" --all-containers --prefix || true
if [ "$STATUS" != "Complete" ]; then
  echo "Job $NS/$JOB FALHOU" >&2
  exit 1
fi
echo "Job $NS/$JOB concluído"
