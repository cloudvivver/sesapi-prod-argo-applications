#!/bin/sh
# Copia arquivos de SRC para DST (mount Mountpoint S3) sem rename/chmod/utime, que o Mountpoint não suporta.
# Não sobrescreve arquivos que já existem no destino (o que já está no S3 prevalece).
# Termina com erro se algum arquivo de SRC não existir em DST ou se algum arquivo copiado nesta execução
# ficar com tamanho diferente.
# Uso: copiar-para-s3.sh <SRC> <DST>
set -eu

SRC="${1:?SRC}"
DST="${2:?DST}"

if [ ! -d "$SRC" ]; then
  echo "Origem $SRC não existe — nada a copiar"
  exit 0
fi

: > /tmp/copiados.txt
: > /tmp/mantidos.txt
cd "$SRC"
find . -type f | sort > /tmp/lista-origem.txt
while IFS= read -r f; do
  destino="$DST/${f#./}"
  if [ -e "$destino" ]; then
    echo "$f" >> /tmp/mantidos.txt
    continue
  fi
  mkdir -p "$(dirname "$destino")"
  cat "$f" > "$destino"
  echo "$f" >> /tmp/copiados.txt
done < /tmp/lista-origem.txt
echo "Copiados: $(wc -l < /tmp/copiados.txt) | já existiam no destino (mantidos): $(wc -l < /tmp/mantidos.txt)"

erros=0
while IFS= read -r f; do
  if [ ! -f "$DST/${f#./}" ]; then
    echo "ERRO: ausente no destino: $f"
    erros=$((erros + 1))
  fi
done < /tmp/lista-origem.txt

while IFS= read -r f; do
  a=$(stat -c '%s' "$SRC/${f#./}")
  b=$(stat -c '%s' "$DST/${f#./}")
  if [ "$a" != "$b" ]; then
    echo "ERRO: tamanho diferente após cópia: $f (origem $a, destino $b)"
    erros=$((erros + 1))
  fi
done < /tmp/copiados.txt

while IFS= read -r f; do
  a=$(stat -c '%s' "$SRC/${f#./}")
  b=$(stat -c '%s' "$DST/${f#./}")
  [ "$a" = "$b" ] || echo "aviso: mantida a versão do destino (origem $a bytes, destino $b bytes): $f"
done < /tmp/mantidos.txt

if [ "$erros" -gt 0 ]; then
  echo "FALHOU: $erros erro(s)"
  exit 1
fi
echo "OK: $(wc -l < /tmp/lista-origem.txt) arquivos da origem presentes no destino"
