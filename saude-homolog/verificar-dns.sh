#!/bin/bash

# Script para verificar configuração DNS
# Uso: ./verificar-dns.sh

set -e

DOMAIN="saude.devel.saude.pi.gov.br"
EXPECTED_TARGET="a8ecc5d6022ed430d83089b7ab2a8873-b481ee7df7e0ce24.elb.sa-east-1.amazonaws.com"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔍 Verificando DNS: $DOMAIN"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# 1. Verificar resolução DNS
echo "1️⃣  Verificando resolução DNS..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if nslookup $DOMAIN > /dev/null 2>&1; then
    echo "✅ DNS resolve!"
    echo ""
    nslookup $DOMAIN | grep -A 2 "Name:"
else
    echo "❌ DNS NÃO resolve ainda"
    echo "   Aguarde propagação DNS (5-10 minutos)"
    echo ""
    echo "💡 Dica: Tente novamente em alguns minutos"
    exit 1
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 2. Verificar CNAME
echo ""
echo "2️⃣  Verificando CNAME..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

CNAME=$(dig +short CNAME $DOMAIN | head -1 | sed 's/\.$//')

if [ -z "$CNAME" ]; then
    echo "⚠️  CNAME não encontrado"
    echo "   Pode ser um A record ao invés de CNAME"

    # Verificar A record
    A_RECORD=$(dig +short A $DOMAIN | head -1)
    if [ ! -z "$A_RECORD" ]; then
        echo "   Encontrado A record: $A_RECORD"
        echo ""
        echo "   ⚠️  ATENÇÃO: É recomendado usar CNAME ao invés de A record"
        echo "   Motivo: ELB IPs podem mudar, CNAME é dinâmico"
    fi
else
    echo "✅ CNAME encontrado: $CNAME"
    echo ""

    if [ "$CNAME" == "$EXPECTED_TARGET" ]; then
        echo "✅ CNAME correto! Aponta para ELB esperado"
    else
        echo "⚠️  CNAME aponta para: $CNAME"
        echo "   Esperado: $EXPECTED_TARGET"
        echo ""
        echo "   Verifique se o CNAME está correto"
    fi
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 3. Verificar resolução completa
echo ""
echo "3️⃣  Verificando resolução completa..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo ""
echo "Cadeia completa de resolução:"
dig +trace $DOMAIN | grep -E "^$DOMAIN|^a8ecc5d6" || true

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 4. Testar conectividade HTTP
echo ""
echo "4️⃣  Testando conectividade HTTP..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

HTTP_STATUS=$(curl -o /dev/null -s -w "%{http_code}" -m 10 http://$DOMAIN 2>/dev/null || echo "000")

echo ""
if [ "$HTTP_STATUS" == "000" ]; then
    echo "❌ Não foi possível conectar via HTTP"
    echo "   Possíveis causas:"
    echo "   - Pods não estão rodando ainda"
    echo "   - Ingress não foi aplicado"
    echo "   - ELB não está saudável"
    echo ""
    echo "   Verificar:"
    echo "   kubectl get pods -n saude-homolog"
    echo "   kubectl get ingress -n saude-homolog"
elif [ "$HTTP_STATUS" == "200" ] || [ "$HTTP_STATUS" == "301" ] || [ "$HTTP_STATUS" == "302" ]; then
    echo "✅ HTTP respondendo! Status: $HTTP_STATUS"
    echo ""
    echo "   Testando headers:"
    curl -I http://$DOMAIN 2>/dev/null | head -10
else
    echo "⚠️  HTTP respondendo com status: $HTTP_STATUS"
    echo ""
    curl -I http://$DOMAIN 2>/dev/null | head -5
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 5. Verificar HTTPS (se configurado)
echo ""
echo "5️⃣  Verificando HTTPS..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

HTTPS_STATUS=$(curl -o /dev/null -s -w "%{http_code}" -m 10 https://$DOMAIN 2>/dev/null || echo "000")

echo ""
if [ "$HTTPS_STATUS" == "000" ]; then
    echo "ℹ️  HTTPS não configurado ainda"
    echo "   Normal se cert-manager não foi instalado"
    echo ""
    echo "   Para habilitar HTTPS:"
    echo "   1. Instalar cert-manager"
    echo "   2. Aplicar cert-manager-setup.yaml"
    echo "   3. Aplicar ingress-with-tls.yaml"
elif [ "$HTTPS_STATUS" == "200" ] || [ "$HTTPS_STATUS" == "301" ] || [ "$HTTPS_STATUS" == "302" ]; then
    echo "✅ HTTPS funcionando! Status: $HTTPS_STATUS"
    echo ""
    echo "   Informações do certificado:"
    echo "   $(openssl s_client -connect $DOMAIN:443 -servername $DOMAIN </dev/null 2>/dev/null | openssl x509 -noout -subject -issuer -dates 2>/dev/null || echo 'Não foi possível obter certificado')"
else
    echo "⚠️  HTTPS respondendo com status: $HTTPS_STATUS"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Resumo final
echo ""
echo "📊 RESUMO"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

DNS_OK=false
HTTP_OK=false
HTTPS_OK=false

if nslookup $DOMAIN > /dev/null 2>&1; then
    echo "✅ DNS configurado e resolvendo"
    DNS_OK=true
else
    echo "❌ DNS não configurado"
fi

if [ "$HTTP_STATUS" == "200" ] || [ "$HTTP_STATUS" == "301" ] || [ "$HTTP_STATUS" == "302" ]; then
    echo "✅ HTTP funcionando (status: $HTTP_STATUS)"
    HTTP_OK=true
else
    echo "❌ HTTP não funcionando (status: $HTTP_STATUS)"
fi

if [ "$HTTPS_STATUS" == "200" ] || [ "$HTTPS_STATUS" == "301" ] || [ "$HTTPS_STATUS" == "302" ]; then
    echo "✅ HTTPS funcionando (status: $HTTPS_STATUS)"
    HTTPS_OK=true
else
    echo "ℹ️  HTTPS não configurado"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ "$DNS_OK" == true ] && [ "$HTTP_OK" == true ]; then
    echo ""
    echo "🎉 SUCESSO! Aplicação está acessível!"
    echo ""
    echo "   Acesse: http://$DOMAIN"

    if [ "$HTTPS_OK" == true ]; then
        echo "   Ou HTTPS: https://$DOMAIN"
    fi

    exit 0
elif [ "$DNS_OK" == true ]; then
    echo ""
    echo "⚠️  DNS configurado mas aplicação não responde"
    echo ""
    echo "   Próximos passos:"
    echo "   1. Verificar se pods estão rodando:"
    echo "      kubectl get pods -n saude-homolog"
    echo ""
    echo "   2. Verificar ingress:"
    echo "      kubectl get ingress -n saude-homolog"
    echo ""
    echo "   3. Ver logs:"
    echo "      kubectl logs -n saude-homolog deployment/webhomolog --tail=20"

    exit 1
else
    echo ""
    echo "❌ DNS ainda não foi configurado"
    echo ""
    echo "   Aguarde configuração pela equipe AWS"
    echo "   Ou envie a solicitação em: SOLICITACAO-DNS.md"

    exit 1
fi
