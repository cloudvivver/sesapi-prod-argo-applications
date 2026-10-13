#!/bin/sh
# Reorganiza o espelho local do MinIO (layout S3 do SDK) no layout de filesystem de Fwk::SharedStorage
# (modo efs), que é o que a app enxerga em /mnt/compartilhado/<DATABASE_PROD>.
#
#   RAW/prd/{sigtap,sia}/                                 → public/prd/{sigtap,sia}/
#   RAW/saude/encerramento_contrato/laboratorio/resultado → public/base_ecerramento/laboratorio/resultado
#   RAW/saude/leito/                                      → leito/
#   RAW/saude/esf/, RAW/saude/encerramento_contrato/      → public/            (efs_dir: 'public')
#   RAW/saude/esu/<arquivo>                               → public/<arquivo>   (CNES, efs_dir: 'public')
#   RAW/saude/esu/<pasta>/                                → public/esu/<pasta>/
#   RAW/saude/<modulo>/ (demais)                          → public/<modulo>/   (efs_dir padrão)
#
# Uso: mapear-minio.sh <RAW> <MAPEADO>
set -eu

RAW="${1:?RAW}"
OUT="${2:?MAPEADO}"
S="$RAW/saude"

mover() {
  [ -d "$1" ] || return 0
  mkdir -p "$2"
  cp -r "$1/." "$2/"
  rm -rf "$1"
}

mkdir -p "$OUT"
mover "$RAW/prd/sigtap" "$OUT/public/prd/sigtap"
mover "$RAW/prd/sia" "$OUT/public/prd/sia"

if [ -d "$S" ]; then
  mover "$S/encerramento_contrato/laboratorio/resultado" "$OUT/public/base_ecerramento/laboratorio/resultado"
  mover "$S/leito" "$OUT/leito"
  mover "$S/esf" "$OUT/public"

  if [ -d "$S/esu" ]; then
    for f in "$S/esu"/*; do
      [ -f "$f" ] || continue
      mkdir -p "$OUT/public"
      cp "$f" "$OUT/public/"
      rm -f "$f"
    done
    mover "$S/esu" "$OUT/public/esu"
  fi

  mover "$S/encerramento_contrato" "$OUT/public"
  mover "$S" "$OUT/public"
fi

echo "Layout mapeado:"
(cd "$OUT" && find . -type f | sort)
