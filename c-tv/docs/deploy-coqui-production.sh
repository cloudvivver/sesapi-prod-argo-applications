#!/bin/bash
#
# Script de Deploy C-TV com Coqui TTS em Produção
# Arquitetura: Servidor Coqui TTS separado + App C-TV
#
# Uso: ./deploy-coqui-production.sh [--voice-file /caminho/para/voz.wav] [--skip-build] [--skip-push]
#

set -e  # Sair em caso de erro

# ============================================================
# CONFIGURAÇÕES
# ============================================================

PROJECT_DIR="/home/cristiano/projetos/saude/c-tv"
K8S_DIR="/home/cristiano/projetos/saude/k8s/c-tv"
ECR_REGISTRY="961341521437.dkr.ecr.sa-east-1.amazonaws.com"
AWS_REGION="sa-east-1"
NAMESPACE="c-tv"

# Nomes das imagens
COQUI_IMAGE_NAME="coqui-tts-server"
APP_IMAGE_NAME="c-tv"

# Tags das imagens
COQUI_IMAGE_TAG="latest"
APP_IMAGE_TAG="latest"

# Imagens completas
COQUI_IMAGE="${ECR_REGISTRY}/${COQUI_IMAGE_NAME}:${COQUI_IMAGE_TAG}"
APP_IMAGE="${ECR_REGISTRY}/${APP_IMAGE_NAME}:${APP_IMAGE_TAG}"

# Flags de controle
SKIP_BUILD=false
SKIP_PUSH=false
VOICE_FILE=""

# ============================================================
# CORES PARA OUTPUT
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ============================================================
# FUNÇÕES AUXILIARES
# ============================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[⚠]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
}

check_command() {
    if ! command -v $1 &> /dev/null; then
        log_error "Comando '$1' não encontrado. Por favor, instale antes de continuar."
        exit 1
    fi
}

# ============================================================
# PARSE DE ARGUMENTOS
# ============================================================

while [[ $# -gt 0 ]]; do
    case $1 in
        --voice-file)
            VOICE_FILE="$2"
            shift 2
            ;;
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        --skip-push)
            SKIP_PUSH=true
            shift
            ;;
        --help)
            echo "Uso: $0 [OPTIONS]"
            echo ""
            echo "Opções:"
            echo "  --voice-file PATH    Caminho para arquivo de voz de referência (WAV)"
            echo "  --skip-build         Pular build das imagens Docker"
            echo "  --skip-push          Pular push das imagens para ECR"
            echo "  --help               Mostrar esta ajuda"
            echo ""
            echo "Exemplo:"
            echo "  $0 --voice-file ~/voice_reference.wav"
            exit 0
            ;;
        *)
            log_error "Argumento desconhecido: $1"
            echo "Use --help para ver as opções disponíveis"
            exit 1
            ;;
    esac
done

# ============================================================
# VALIDAÇÕES INICIAIS
# ============================================================

log_info "🚀 Iniciando deploy do C-TV com Coqui TTS em produção..."
echo ""

# Verificar comandos necessários
log_info "Verificando dependências..."
check_command docker
check_command kubectl
check_command aws
log_success "Todas as dependências encontradas"
echo ""

# Verificar diretórios
if [ ! -d "$PROJECT_DIR" ]; then
    log_error "Diretório do projeto não encontrado: $PROJECT_DIR"
    exit 1
fi

if [ ! -d "$K8S_DIR" ]; then
    log_error "Diretório Kubernetes não encontrado: $K8S_DIR"
    exit 1
fi

# Verificar arquivo de voz (se fornecido)
if [ -n "$VOICE_FILE" ]; then
    if [ ! -f "$VOICE_FILE" ]; then
        log_error "Arquivo de voz não encontrado: $VOICE_FILE"
        exit 1
    fi
    log_success "Arquivo de voz encontrado: $VOICE_FILE"
else
    log_warning "Arquivo de voz não fornecido. Certifique-se de que o secret já existe no cluster."
    log_warning "Use: kubectl get secret coqui-voice-reference -n $NAMESPACE"
fi
echo ""

# ============================================================
# PASSO 1: LOGIN NO ECR
# ============================================================

log_info "📦 Passo 1/6: Fazendo login no ECR..."
if aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $ECR_REGISTRY; then
    log_success "Login no ECR realizado com sucesso"
else
    log_error "Falha ao fazer login no ECR"
    exit 1
fi
echo ""

# ============================================================
# PASSO 2: BUILD DAS IMAGENS
# ============================================================

if [ "$SKIP_BUILD" = false ]; then
    log_info "🔨 Passo 2/6: Construindo imagens Docker..."

    cd "$PROJECT_DIR"

    # Build do servidor Coqui
    log_info "Construindo imagem do servidor Coqui TTS..."
    if docker build -f Dockerfile.coqui-server -t ${COQUI_IMAGE_NAME}:${COQUI_IMAGE_TAG} .; then
        log_success "Imagem do servidor Coqui construída: ${COQUI_IMAGE_NAME}:${COQUI_IMAGE_TAG}"
    else
        log_error "Falha ao construir imagem do servidor Coqui"
        exit 1
    fi

    # Build da aplicação C-TV
    log_info "Construindo imagem da aplicação C-TV..."
    if docker build -f Dockerfile.prod -t ${APP_IMAGE_NAME}:${APP_IMAGE_TAG} .; then
        log_success "Imagem da aplicação C-TV construída: ${APP_IMAGE_NAME}:${APP_IMAGE_TAG}"
    else
        log_error "Falha ao construir imagem da aplicação C-TV"
        exit 1
    fi

    # Tag das imagens para ECR
    log_info "Criando tags para ECR..."
    docker tag ${COQUI_IMAGE_NAME}:${COQUI_IMAGE_TAG} ${COQUI_IMAGE}
    docker tag ${APP_IMAGE_NAME}:${APP_IMAGE_TAG} ${APP_IMAGE}
    log_success "Tags criadas com sucesso"
else
    log_warning "Build pulado (--skip-build)"
fi
echo ""

# ============================================================
# PASSO 3: PUSH DAS IMAGENS PARA ECR
# ============================================================

if [ "$SKIP_PUSH" = false ]; then
    log_info "📤 Passo 3/6: Enviando imagens para ECR..."

    # Push do servidor Coqui
    log_info "Enviando imagem do servidor Coqui..."
    if docker push ${COQUI_IMAGE}; then
        log_success "Imagem do servidor Coqui enviada: ${COQUI_IMAGE}"
    else
        log_error "Falha ao enviar imagem do servidor Coqui"
        exit 1
    fi

    # Push da aplicação C-TV
    log_info "Enviando imagem da aplicação C-TV..."
    if docker push ${APP_IMAGE}; then
        log_success "Imagem da aplicação C-TV enviada: ${APP_IMAGE}"
    else
        log_error "Falha ao enviar imagem da aplicação C-TV"
        exit 1
    fi
else
    log_warning "Push pulado (--skip-push)"
fi
echo ""

# ============================================================
# PASSO 4: CRIAR SECRET DA VOZ (se fornecido)
# ============================================================

log_info "🔐 Passo 4/6: Configurando secret da voz de referência..."

if [ -n "$VOICE_FILE" ]; then
    # Verificar se namespace existe
    if ! kubectl get namespace $NAMESPACE &> /dev/null; then
        log_info "Criando namespace $NAMESPACE..."
        kubectl create namespace $NAMESPACE
        log_success "Namespace criado"
    fi

    # Verificar se secret já existe
    if kubectl get secret coqui-voice-reference -n $NAMESPACE &> /dev/null; then
        log_warning "Secret 'coqui-voice-reference' já existe. Deseja recriar? (s/N)"
        read -r response
        if [[ "$response" =~ ^([sS][iI][mM]|[sS])$ ]]; then
            kubectl delete secret coqui-voice-reference -n $NAMESPACE
            log_info "Secret antigo removido"
        else
            log_info "Mantendo secret existente"
            VOICE_FILE=""
        fi
    fi

    if [ -n "$VOICE_FILE" ]; then
        log_info "Criando secret com arquivo de voz: $VOICE_FILE"
        if kubectl create secret generic coqui-voice-reference \
            --from-file=reference_voice.wav="$VOICE_FILE" \
            --namespace $NAMESPACE; then
            log_success "Secret criado com sucesso"
        else
            log_error "Falha ao criar secret"
            exit 1
        fi
    fi
else
    # Verificar se secret existe
    if kubectl get secret coqui-voice-reference -n $NAMESPACE &> /dev/null; then
        log_success "Secret 'coqui-voice-reference' já existe no cluster"
    else
        log_error "Secret 'coqui-voice-reference' não encontrado e arquivo não fornecido"
        log_error "Use --voice-file para fornecer o arquivo ou crie o secret manualmente"
        exit 1
    fi
fi
echo ""

# ============================================================
# PASSO 5: APLICAR MANIFESTS KUBERNETES
# ============================================================

log_info "☸️  Passo 5/6: Aplicando manifests Kubernetes..."

cd "$K8S_DIR"

# Aplicar ConfigMap
log_info "Aplicando ConfigMap..."
if kubectl apply -f env-configmap.yaml; then
    log_success "ConfigMap aplicado"
else
    log_error "Falha ao aplicar ConfigMap"
    exit 1
fi

# Aplicar deployment e service do servidor Coqui
log_info "Aplicando deployment do servidor Coqui..."
if kubectl apply -f coqui-deployment.yaml; then
    log_success "Deployment do servidor Coqui aplicado"
else
    log_error "Falha ao aplicar deployment do servidor Coqui"
    exit 1
fi

log_info "Aplicando service do servidor Coqui..."
if kubectl apply -f coqui-service.yaml; then
    log_success "Service do servidor Coqui aplicado"
else
    log_error "Falha ao aplicar service do servidor Coqui"
    exit 1
fi

# Aplicar deployment e service da aplicação C-TV
log_info "Aplicando deployment da aplicação C-TV..."
if kubectl apply -f web-deployment.yaml; then
    log_success "Deployment da aplicação C-TV aplicado"
else
    log_error "Falha ao aplicar deployment da aplicação C-TV"
    exit 1
fi

log_info "Aplicando service da aplicação C-TV..."
if kubectl apply -f web-service.yaml; then
    log_success "Service da aplicação C-TV aplicado"
else
    log_error "Falha ao aplicar service da aplicação C-TV"
    exit 1
fi

# Aplicar ingress (se existir)
if [ -f "web-ingress.yaml" ]; then
    log_info "Aplicando ingress..."
    if kubectl apply -f web-ingress.yaml; then
        log_success "Ingress aplicado"
    else
        log_warning "Falha ao aplicar ingress (continuando...)"
    fi
fi

echo ""

# ============================================================
# PASSO 6: VERIFICAR DEPLOYMENT
# ============================================================

log_info "🔍 Passo 6/6: Verificando deployment..."

log_info "Aguardando pods ficarem prontos..."

# Aguardar servidor Coqui
log_info "Aguardando servidor Coqui TTS (pode levar ~3 minutos)..."
if kubectl wait --for=condition=ready pod -l app.kubernetes.io/component=coqui-tts -n $NAMESPACE --timeout=300s; then
    log_success "Servidor Coqui TTS está pronto"
else
    log_warning "Timeout aguardando servidor Coqui. Verifique os logs com: kubectl logs -f deployment/coqui-server -n $NAMESPACE"
fi

# Aguardar aplicação C-TV
log_info "Aguardando aplicação C-TV..."
if kubectl wait --for=condition=ready pod -l app.kubernetes.io/component=web -n $NAMESPACE --timeout=120s; then
    log_success "Aplicação C-TV está pronta"
else
    log_warning "Timeout aguardando aplicação C-TV. Verifique os logs com: kubectl logs -f deployment/web -n $NAMESPACE"
fi

echo ""

# ============================================================
# RESUMO
# ============================================================

log_success "=========================================="
log_success "✓ Deploy concluído com sucesso!"
log_success "=========================================="
echo ""

log_info "📊 Status dos pods:"
kubectl get pods -n $NAMESPACE
echo ""

log_info "🔗 Services:"
kubectl get svc -n $NAMESPACE
echo ""

log_info "📝 Comandos úteis:"
echo ""
echo "  # Ver logs do servidor Coqui:"
echo "  kubectl logs -f deployment/coqui-server -n $NAMESPACE"
echo ""
echo "  # Ver logs da aplicação C-TV:"
echo "  kubectl logs -f deployment/web -n $NAMESPACE"
echo ""
echo "  # Testar servidor Coqui (port-forward):"
echo "  kubectl port-forward svc/coqui-server 5000:5000 -n $NAMESPACE"
echo "  curl http://localhost:5000/health"
echo ""
echo "  # Testar aplicação C-TV (port-forward):"
echo "  kubectl port-forward svc/web-service 8080:8080 -n $NAMESPACE"
echo "  curl http://localhost:8080/health"
echo ""
echo "  # Ver recursos utilizados:"
echo "  kubectl top pods -n $NAMESPACE"
echo ""

log_info "📚 Documentação completa: $K8S_DIR/DEPLOY_COQUI_PRODUCTION.md"
echo ""

log_success "🎉 Deploy finalizado!"
