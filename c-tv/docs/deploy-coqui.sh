#!/bin/bash

# Script de deploy do C-TV com Coqui TTS no Kubernetes
# Uso: ./deploy-coqui.sh [--skip-build] [--skip-secret]

set -e

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Variáveis
ECR_REGISTRY="961341521437.dkr.ecr.sa-east-1.amazonaws.com"
AWS_REGION="sa-east-1"
NAMESPACE="c-tv"
VOICE_FILE="../../voice_samples/reference_voice.wav"

# Flags
SKIP_BUILD=false
SKIP_SECRET=false

# Parse argumentos
for arg in "$@"; do
  case $arg in
    --skip-build)
      SKIP_BUILD=true
      shift
      ;;
    --skip-secret)
      SKIP_SECRET=true
      shift
      ;;
    --help)
      echo "Uso: $0 [--skip-build] [--skip-secret]"
      echo "  --skip-build   : Pula build e push das imagens Docker"
      echo "  --skip-secret  : Pula criação do secret de voz"
      exit 0
      ;;
  esac
done

echo -e "${GREEN}=== Deploy C-TV com Coqui TTS ===${NC}\n"

# 1. Criar namespace se não existe
echo -e "${YELLOW}[1/7] Verificando namespace...${NC}"
kubectl get namespace $NAMESPACE >/dev/null 2>&1 || kubectl create namespace $NAMESPACE
echo -e "${GREEN}✓ Namespace OK${NC}\n"

# 2. Criar secret da voz (se não existir)
if [ "$SKIP_SECRET" = false ]; then
  echo -e "${YELLOW}[2/7] Criando secret da voz de referência...${NC}"

  if [ ! -f "$VOICE_FILE" ]; then
    echo -e "${RED}ERRO: Arquivo de voz não encontrado em $VOICE_FILE${NC}"
    echo "Coloque o arquivo de voz de referência em: $VOICE_FILE"
    exit 1
  fi

  # Remover secret existente se houver
  kubectl delete secret coqui-voice-reference -n $NAMESPACE 2>/dev/null || true

  # Criar novo secret
  kubectl create secret generic coqui-voice-reference \
    --from-file=reference_voice.wav=$VOICE_FILE \
    --namespace=$NAMESPACE

  echo -e "${GREEN}✓ Secret criado${NC}\n"
else
  echo -e "${YELLOW}[2/7] Pulando criação do secret (--skip-secret)${NC}\n"
fi

# 3. Build e push das imagens (se não pular)
if [ "$SKIP_BUILD" = false ]; then
  echo -e "${YELLOW}[3/7] Build e push das imagens Docker...${NC}"

  cd ../../

  # Login no ECR
  echo "Fazendo login no ECR..."
  aws ecr get-login-password --region $AWS_REGION | \
    docker login --username AWS --password-stdin $ECR_REGISTRY

  # Build e push Backend
  echo "Building c-tv backend..."
  docker build -f Dockerfile.prod -t c-tv:latest .
  docker tag c-tv:latest $ECR_REGISTRY/c-tv:latest
  docker push $ECR_REGISTRY/c-tv:latest

  # Build e push Coqui Server
  echo "Building coqui-tts-server..."
  docker build -f Dockerfile.coqui-server -t coqui-tts-server:latest .
  docker tag coqui-tts-server:latest $ECR_REGISTRY/coqui-tts-server:latest
  docker push $ECR_REGISTRY/coqui-tts-server:latest

  cd k8s/c-tv/

  echo -e "${GREEN}✓ Imagens publicadas${NC}\n"
else
  echo -e "${YELLOW}[3/7] Pulando build de imagens (--skip-build)${NC}\n"
fi

# 4. Aplicar ConfigMap
echo -e "${YELLOW}[4/7] Aplicando ConfigMap...${NC}"
kubectl apply -f env-configmap.yaml
echo -e "${GREEN}✓ ConfigMap aplicado${NC}\n"

# 5. Aplicar PVC
echo -e "${YELLOW}[5/7] Aplicando PVC de cache...${NC}"
kubectl apply -f audio-cache-pvc.yaml
echo -e "${GREEN}✓ PVC aplicado${NC}\n"

# 6. Aplicar Services
echo -e "${YELLOW}[6/7] Aplicando Services...${NC}"
kubectl apply -f coqui-service.yaml
kubectl apply -f web-service.yaml
echo -e "${GREEN}✓ Services aplicados${NC}\n"

# 7. Aplicar Deployments
echo -e "${YELLOW}[7/9] Aplicando Deployments...${NC}"
kubectl apply -f coqui-deployment.yaml
kubectl apply -f web-deployment.yaml
echo -e "${GREEN}✓ Deployments aplicados${NC}\n"

# 8. Aplicar ClusterIssuer (cert-manager)
echo -e "${YELLOW}[8/9] Aplicando ClusterIssuer do cert-manager...${NC}"
kubectl apply -f cert-manager-issuer.yaml 2>/dev/null || echo "ClusterIssuer já existe ou cert-manager não instalado"
echo -e "${GREEN}✓ ClusterIssuer verificado${NC}\n"

# 9. Aplicar Ingress
echo -e "${YELLOW}[9/9] Aplicando Ingress HTTPS...${NC}"
kubectl apply -f web-ingress.yaml
echo -e "${GREEN}✓ Ingress aplicado${NC}\n"

# Aguardar rollout
echo -e "${YELLOW}Aguardando rollout dos deployments...${NC}"
kubectl rollout status deployment/coqui-server -n $NAMESPACE --timeout=10m
kubectl rollout status deployment/web -n $NAMESPACE --timeout=5m

# Status final
echo -e "\n${GREEN}=== Deploy concluído com sucesso! ===${NC}\n"

echo "Status dos pods:"
kubectl get pods -n $NAMESPACE

echo -e "\nStatus dos services:"
kubectl get svc -n $NAMESPACE

echo -e "\n${YELLOW}Dica: Use os comandos abaixo para verificar os logs:${NC}"
echo "  kubectl logs -f deployment/coqui-server -n $NAMESPACE"
echo "  kubectl logs -f deployment/web -n $NAMESPACE"

echo -e "\n${YELLOW}Para testar o TTS:${NC}"
echo "  kubectl port-forward -n $NAMESPACE deployment/web 8080:8080"
echo "  curl 'http://localhost:8080/speak?key=e38cade885ddd37895267ba0ff210551&texto=TESTE&voz=coqui' -o test.wav"

echo -e "\n${YELLOW}Status do Ingress:${NC}"
kubectl get ingress -n $NAMESPACE

echo -e "\n${YELLOW}Certificado SSL:${NC}"
kubectl get certificate -n $NAMESPACE 2>/dev/null || echo "Aguardando emissão do certificado..."

echo -e "\n${GREEN}URL de acesso:${NC} https://c-tv.saude.pi.gov.br"
echo -e "${YELLOW}Nota:${NC} O certificado SSL pode levar 1-2 minutos para ser emitido pelo Let's Encrypt"
echo -e "${YELLOW}Verificar certificado:${NC} kubectl get certificate -n $NAMESPACE -w"
