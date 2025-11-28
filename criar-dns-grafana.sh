#!/bin/bash

# Script para criar DNS do Grafana no Route 53
# Uso: ./criar-dns-grafana.sh

set -e

echo "=== Criando DNS para Grafana ==="

# 1. Buscar Hosted Zone ID do domínio saude.pi.gov.br
ZONE_ID=$(aws route53 list-hosted-zones \
  --query "HostedZones[?Name=='saude.pi.gov.br.'].Id" \
  --output text | cut -d'/' -f3)

if [ -z "$ZONE_ID" ]; then
  echo "❌ ERRO: Zona saude.pi.gov.br não encontrada no Route 53"
  echo "Verifique se você tem acesso ao Route 53 ou crie o DNS manualmente"
  exit 1
fi

echo "✅ Zona encontrada: $ZONE_ID"

# 2. Verificar se o registro já existe
EXISTING=$(aws route53 list-resource-record-sets \
  --hosted-zone-id "$ZONE_ID" \
  --query "ResourceRecordSets[?Name=='grafana.saude.pi.gov.br.'].Name" \
  --output text)

if [ ! -z "$EXISTING" ]; then
  echo "⚠️  O registro grafana.saude.pi.gov.br já existe!"
  echo "Deseja sobrescrever? (s/n)"
  read -r resposta
  if [ "$resposta" != "s" ]; then
    echo "Operação cancelada"
    exit 0
  fi
  ACTION="UPSERT"
else
  ACTION="CREATE"
fi

# 3. Criar arquivo JSON com o registro
cat > /tmp/grafana-dns-change.json <<EOF
{
  "Changes": [{
    "Action": "$ACTION",
    "ResourceRecordSet": {
      "Name": "grafana.saude.pi.gov.br",
      "Type": "CNAME",
      "TTL": 300,
      "ResourceRecords": [{
        "Value": "a8ecc5d6022ed430d83089b7ab2a8873-b481ee7df7e0ce24.elb.sa-east-1.amazonaws.com"
      }]
    }
  }]
}
EOF

# 4. Aplicar a mudança no Route 53
echo "📝 Criando registro CNAME..."
CHANGE_ID=$(aws route53 change-resource-record-sets \
  --hosted-zone-id "$ZONE_ID" \
  --change-batch file:///tmp/grafana-dns-change.json \
  --query 'ChangeInfo.Id' \
  --output text)

echo "✅ Registro criado/atualizado com sucesso!"
echo "Change ID: $CHANGE_ID"

# 5. Aguardar propagação
echo ""
echo "⏳ Aguardando propagação do DNS (isso pode levar alguns minutos)..."
aws route53 wait resource-record-sets-changed --id "$CHANGE_ID"

echo ""
echo "✅ DNS propagado com sucesso!"
echo ""
echo "🔍 Testando resolução DNS..."
sleep 5
nslookup grafana.saude.pi.gov.br 8.8.8.8 || echo "DNS ainda propagando..."

echo ""
echo "🎉 Pronto! Agora você pode acessar:"
echo "   https://grafana.saude.pi.gov.br"
echo ""
echo "⚠️  Nota: O certificado SSL será gerado automaticamente pelo cert-manager"
echo "   Pode levar até 5 minutos para o certificado ficar pronto"

# Limpar arquivo temporário
rm -f /tmp/grafana-dns-change.json
