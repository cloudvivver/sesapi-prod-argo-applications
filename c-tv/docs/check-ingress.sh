#!/bin/bash

# Script de verificação do Ingress HTTPS
# Uso: ./check-ingress.sh

set -e

# Cores
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

NAMESPACE="c-tv"
DOMAIN="c-tv.saude.pi.gov.br"

echo -e "${GREEN}=== Verificação do Ingress HTTPS ===${NC}\n"

# 1. Verificar NGINX Ingress Controller
echo -e "${YELLOW}[1] NGINX Ingress Controller${NC}"
if kubectl get pods -n ingress-nginx &>/dev/null; then
    INGRESS_PODS=$(kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller -o name | wc -l)
    if [ "$INGRESS_PODS" -gt 0 ]; then
        echo -e "${GREEN}✓ NGINX Ingress instalado ($INGRESS_PODS pods)${NC}"
        kubectl get svc -n ingress-nginx ingress-nginx-controller
    else
        echo -e "${RED}✗ NGINX Ingress não encontrado${NC}"
    fi
else
    echo -e "${RED}✗ Namespace ingress-nginx não existe${NC}"
fi
echo ""

# 2. Verificar cert-manager
echo -e "${YELLOW}[2] cert-manager${NC}"
if kubectl get pods -n cert-manager &>/dev/null; then
    CERT_PODS=$(kubectl get pods -n cert-manager -o name | wc -l)
    echo -e "${GREEN}✓ cert-manager instalado ($CERT_PODS pods)${NC}"
    kubectl get clusterissuer 2>/dev/null || echo "Nenhum ClusterIssuer encontrado"
else
    echo -e "${RED}✗ cert-manager não instalado${NC}"
fi
echo ""

# 3. Verificar DNS
echo -e "${YELLOW}[3] Resolução DNS${NC}"
DNS_IP=$(nslookup $DOMAIN 2>/dev/null | grep -A1 "Name:" | tail -1 | awk '{print $2}')
if [ -n "$DNS_IP" ]; then
    echo -e "${GREEN}✓ DNS resolvendo: $DOMAIN → $DNS_IP${NC}"
else
    echo -e "${RED}✗ DNS não está resolvendo${NC}"
fi
echo ""

# 4. Verificar Ingress
echo -e "${YELLOW}[4] Ingress Resource${NC}"
if kubectl get ingress -n $NAMESPACE web-ingress &>/dev/null; then
    echo -e "${GREEN}✓ Ingress criado${NC}"
    kubectl get ingress -n $NAMESPACE web-ingress
else
    echo -e "${RED}✗ Ingress não encontrado${NC}"
fi
echo ""

# 5. Verificar Certificado
echo -e "${YELLOW}[5] Certificado SSL${NC}"
if kubectl get certificate -n $NAMESPACE &>/dev/null; then
    CERT_STATUS=$(kubectl get certificate -n $NAMESPACE c-tv-tls -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    if [ "$CERT_STATUS" == "True" ]; then
        echo -e "${GREEN}✓ Certificado emitido e válido${NC}"
        kubectl get certificate -n $NAMESPACE

        # Mostrar data de expiração
        EXPIRY=$(kubectl get certificate -n $NAMESPACE c-tv-tls -o jsonpath='{.status.notAfter}' 2>/dev/null)
        if [ -n "$EXPIRY" ]; then
            echo -e "Expira em: $EXPIRY"
        fi
    else
        echo -e "${YELLOW}⚠ Certificado não pronto (Status: $CERT_STATUS)${NC}"
        kubectl get certificate -n $NAMESPACE

        # Ver desafios pendentes
        CHALLENGES=$(kubectl get challenge -n $NAMESPACE 2>/dev/null | wc -l)
        if [ "$CHALLENGES" -gt 1 ]; then
            echo -e "\n${YELLOW}Desafios HTTP-01 pendentes:${NC}"
            kubectl get challenge -n $NAMESPACE
        fi
    fi
else
    echo -e "${RED}✗ Nenhum certificado encontrado${NC}"
    echo "Execute: kubectl get certificate -n $NAMESPACE"
fi
echo ""

# 6. Verificar Service
echo -e "${YELLOW}[6] Service Backend${NC}"
if kubectl get svc -n $NAMESPACE web-service &>/dev/null; then
    echo -e "${GREEN}✓ Service criado${NC}"
    kubectl get svc -n $NAMESPACE web-service

    # Verificar endpoints
    ENDPOINTS=$(kubectl get endpoints -n $NAMESPACE web-service -o jsonpath='{.subsets[*].addresses[*].ip}' | wc -w)
    if [ "$ENDPOINTS" -gt 0 ]; then
        echo -e "${GREEN}✓ $ENDPOINTS endpoints prontos${NC}"
    else
        echo -e "${RED}✗ Nenhum endpoint disponível${NC}"
    fi
else
    echo -e "${RED}✗ Service não encontrado${NC}"
fi
echo ""

# 7. Verificar Pods
echo -e "${YELLOW}[7] Pods Backend${NC}"
kubectl get pods -n $NAMESPACE -l app.kubernetes.io/component=web
echo ""

# 8. Teste HTTPS
echo -e "${YELLOW}[8] Teste de Conectividade HTTPS${NC}"
if command -v curl &> /dev/null; then
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" https://$DOMAIN/health 2>/dev/null || echo "000")

    if [ "$HTTP_CODE" == "200" ]; then
        echo -e "${GREEN}✓ HTTPS funcionando (HTTP $HTTP_CODE)${NC}"

        # Verificar certificado
        CERT_ISSUER=$(echo | openssl s_client -connect $DOMAIN:443 -servername $DOMAIN 2>/dev/null | \
                     openssl x509 -noout -issuer 2>/dev/null | grep -o "Let's Encrypt" || echo "")

        if [ -n "$CERT_ISSUER" ]; then
            echo -e "${GREEN}✓ Certificado emitido por Let's Encrypt${NC}"
        fi

        # Verificar datas
        CERT_DATES=$(echo | openssl s_client -connect $DOMAIN:443 -servername $DOMAIN 2>/dev/null | \
                    openssl x509 -noout -dates 2>/dev/null)
        if [ -n "$CERT_DATES" ]; then
            echo "$CERT_DATES"
        fi
    else
        echo -e "${RED}✗ HTTPS não acessível (HTTP $HTTP_CODE)${NC}"

        # Testar HTTP (pode estar redirecionando)
        HTTP_REDIRECT=$(curl -s -o /dev/null -w "%{http_code}" http://$DOMAIN/health 2>/dev/null || echo "000")
        if [ "$HTTP_REDIRECT" == "308" ] || [ "$HTTP_REDIRECT" == "301" ]; then
            echo -e "${YELLOW}⚠ HTTP redireciona para HTTPS (HTTP $HTTP_REDIRECT)${NC}"
        fi
    fi
else
    echo -e "${YELLOW}⚠ curl não instalado, pulando teste${NC}"
fi
echo ""

# 9. Resumo
echo -e "${GREEN}=== Resumo ===${NC}"
echo -e "URL: ${GREEN}https://$DOMAIN${NC}"
echo ""
echo "Comandos úteis:"
echo "  kubectl get ingress -n $NAMESPACE"
echo "  kubectl get certificate -n $NAMESPACE -w"
echo "  kubectl describe ingress web-ingress -n $NAMESPACE"
echo "  kubectl logs -n ingress-nginx deployment/ingress-nginx-controller"
echo "  kubectl logs -n cert-manager deployment/cert-manager"
