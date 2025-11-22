# Deploy do C-TV no Kubernetes

Guia rápido de deploy do C-TV com Coqui TTS no Kubernetes EKS.

## 📊 Status Atual

- ✅ **Backend**: 1 réplica (sem EFS)
- ✅ **Coqui TTS**: 1 réplica
- ✅ **HTTPS**: Configurado (Let's Encrypt)
- ✅ **Cache**: PVC 10GB ReadWriteOnce (gp2/gp3)
- ⚠️ **EFS**: Aguardando aprovação

## 🚀 Deploy Rápido

### 1. Pré-requisitos

```bash
# Verificar acesso ao cluster
kubectl cluster-info

# Verificar se cert-manager está instalado
kubectl get pods -n cert-manager

# Verificar se NGINX Ingress está instalado
kubectl get pods -n ingress-nginx
```

### 2. Preparar Imagens Docker

```bash
cd /home/cristiano/projetos/saude/c-tv

# Build e push das imagens já foi feito:
# - 961341521437.dkr.ecr.sa-east-1.amazonaws.com/c-tv:latest
# - 961341521437.dkr.ecr.sa-east-1.amazonaws.com/coqui-tts-server:latest
```

### 3. Criar Secret da Voz

```bash
# Criar secret com arquivo de voz de referência
kubectl create secret generic coqui-voice-reference \
  --from-file=reference_voice.wav=./voice_samples/reference_voice.wav \
  --namespace=c-tv
```

### 4. Executar Deploy

```bash
cd k8s/c-tv

# Deploy completo (automatizado)
./deploy-coqui.sh

# Ou pular build de imagens se já foram feitas
./deploy-coqui.sh --skip-build
```

### 5. Verificar Deploy

```bash
# Verificar pods
kubectl get pods -n c-tv -w

# Verificar certificado SSL
kubectl get certificate -n c-tv -w

# Verificar Ingress
kubectl get ingress -n c-tv

# Script de verificação completa
./check-ingress.sh
```

## 📁 Arquivos Importantes

### Manifestos do Kubernetes

- **namespace.yaml** - Namespace c-tv
- **env-configmap.yaml** - Variáveis de ambiente
- **audio-cache-pvc.yaml** - PVC 10GB (RWO, sem EFS)
- **coqui-deployment.yaml** - Deployment do Coqui Server
- **coqui-service.yaml** - Service interno do Coqui
- **web-deployment.yaml** - Deployment do backend (1 réplica)
- **web-service.yaml** - Service do backend
- **web-ingress.yaml** - Ingress HTTPS
- **cert-manager-issuer.yaml** - ClusterIssuer Let's Encrypt

### Scripts

- **deploy-coqui.sh** - Deploy automatizado completo
- **check-ingress.sh** - Verificação do Ingress HTTPS

### Documentação

- **COQUI_SETUP.md** - Guia completo de setup do Coqui TTS
- **INGRESS_SETUP.md** - Guia de configuração HTTPS
- **MIGRAR_PARA_EFS.md** - Guia de migração para EFS (futuro)
- **README-DEPLOY.md** - Este arquivo

## 🔍 Verificações Pós-Deploy

### 1. Pods Rodando

```bash
kubectl get pods -n c-tv

# Deve mostrar:
# coqui-server-xxx    1/1     Running
# web-xxx             1/1     Running
```

### 2. Certificado SSL Emitido

```bash
kubectl get certificate -n c-tv

# Deve mostrar:
# c-tv-tls   True   c-tv-tls   2m
```

### 3. Acesso HTTPS

```bash
# Teste básico
curl -I https://c-tv.saude.pi.gov.br/health

# Deve retornar: HTTP/2 200
```

### 4. TTS Funcionando

```bash
# Port-forward temporário
kubectl port-forward -n c-tv deployment/web 8080:8080

# Em outro terminal
curl 'http://localhost:8080/speak?key=e38cade885ddd37895267ba0ff210551&texto=TESTE&voz=coqui' -o test.wav

# Verificar arquivo
file test.wav
# Deve mostrar: RIFF (little-endian) data, WAVE audio
```

## 📊 Arquitetura Atual (Sem EFS)

```
┌─────────────────────────────────────┐
│  Ingress (c-tv.saude.pi.gov.br)     │
│  - HTTPS (Let's Encrypt)            │
│  - WebSocket Support                │
└──────────────┬──────────────────────┘
               │
        ┌──────▼──────┐
        │ web-service │
        └──────┬──────┘
               │
┌──────────────▼────────────────┐
│  web-deployment (1 replica)   │
│  + Pod Affinity (same node)   │
│  + Monta: PVC RWO             │
└──────────┬────────────────────┘
           │
           │ HTTP
           │
           ▼
┌──────────────────────────┐
│  coqui-server (1 replica)│
│  + Monta: PVC RWO        │
└──────────┬───────────────┘
           │
           ▼
┌──────────────────────────┐
│  PVC: audio-cache        │
│  - 10GB ReadWriteOnce    │
│  - gp2/gp3 padrão        │
└──────────────────────────┘
```

**Nota**: Ambos os pods rodam no **mesmo nó** (Pod Affinity) para compartilhar o PVC RWO.

## ⚙️ Configuração

### Variáveis de Ambiente (ConfigMap)

```yaml
TTS_PROVIDER: "coqui-http"
COQUI_SERVER_URL: "http://coqui-server:5000"
CACHE_DIRECTORY: "/app/cache_audio"
CTV_ENV: "prod"
CTV_SSL: "TRUE"
```

### Recursos

**Backend:**
- CPU: 500m request, 1000m limit
- RAM: 512Mi request, 1Gi limit

**Coqui Server:**
- CPU: 1000m request, 2000m limit
- RAM: 3Gi request, 5Gi limit

## 🔄 Atualizações

### Atualizar Backend

```bash
# Build nova imagem
cd /home/cristiano/projetos/saude/c-tv
docker build -f Dockerfile.prod -t c-tv:latest .

# Push para ECR
docker tag c-tv:latest 961341521437.dkr.ecr.sa-east-1.amazonaws.com/c-tv:latest
docker push 961341521437.dkr.ecr.sa-east-1.amazonaws.com/c-tv:latest

# Restart deployment (Recreate - breve downtime)
kubectl rollout restart deployment/web -n c-tv
kubectl rollout status deployment/web -n c-tv
```

### Atualizar Coqui Server

```bash
# Build nova imagem
docker build -f Dockerfile.coqui-server -t coqui-tts-server:latest .

# Push para ECR
docker tag coqui-tts-server:latest 961341521437.dkr.ecr.sa-east-1.amazonaws.com/coqui-tts-server:latest
docker push 961341521437.dkr.ecr.sa-east-1.amazonaws.com/coqui-tts-server:latest

# Restart (pode demorar ~5min para recarregar modelo)
kubectl rollout restart deployment/coqui-server -n c-tv
kubectl rollout status deployment/coqui-server -n c-tv
```

## 🐛 Troubleshooting

### Pods não iniciam

```bash
# Ver eventos
kubectl describe pod -n c-tv <pod-name>

# Ver logs
kubectl logs -n c-tv <pod-name>
```

### Certificado SSL não emitido

```bash
# Ver status
kubectl describe certificate c-tv-tls -n c-tv

# Ver desafios
kubectl get challenge -n c-tv
```

### TTS retorna erro 500

```bash
# Ver logs do backend
kubectl logs -n c-tv deployment/web

# Ver logs do Coqui
kubectl logs -n c-tv deployment/coqui-server

# Testar conectividade
kubectl exec -n c-tv deployment/web -- wget -O- http://coqui-server:5000/health
```

### Pods em nós diferentes (PVC não monta)

```bash
# Ver em qual nó cada pod está
kubectl get pods -n c-tv -o wide

# Devem estar no MESMO nó devido ao Pod Affinity

# Se não estiverem, verificar affinity
kubectl get deployment web -n c-tv -o yaml | grep -A20 affinity
```

## 📈 Próximos Passos

### Quando EFS for Aprovado

1. Seguir guia: **MIGRAR_PARA_EFS.md**
2. Benefícios:
   - ✅ 3 réplicas do backend (alta disponibilidade)
   - ✅ Zero downtime em atualizações
   - ✅ Cache compartilhado entre todos os pods

## 🔗 Links Úteis

- **Aplicação**: https://c-tv.saude.pi.gov.br
- **Health Check**: https://c-tv.saude.pi.gov.br/health
- **ECR Backend**: 961341521437.dkr.ecr.sa-east-1.amazonaws.com/c-tv
- **ECR Coqui**: 961341521437.dkr.ecr.sa-east-1.amazonaws.com/coqui-tts-server

## 📞 Suporte

Em caso de problemas:

1. Ver logs: `kubectl logs -n c-tv deployment/<name>`
2. Ver eventos: `kubectl get events -n c-tv --sort-by='.lastTimestamp'`
3. Executar: `./check-ingress.sh`
4. Consultar documentação específica em `COQUI_SETUP.md` ou `INGRESS_SETUP.md`
