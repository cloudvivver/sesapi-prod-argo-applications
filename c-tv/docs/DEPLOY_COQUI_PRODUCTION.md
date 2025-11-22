# Deploy C-TV com Coqui TTS em Produção (ArgoCD/Kubernetes)

Este guia descreve o processo completo para fazer deployment do C-TV com Coqui TTS em produção usando ArgoCD e Kubernetes.

## 📋 Arquitetura

A solução utiliza **arquitetura de 2 deployments separados**:

1. **Servidor Coqui TTS** (`coqui-deployment.yaml`)
   - Servidor Flask HTTP persistente
   - Mantém modelo XTTS-v2 carregado em memória
   - Porta: 5000
   - Recursos: 3-5GB RAM

2. **Aplicação C-TV** (`web-deployment.yaml`)
   - Backend Go + Frontend Quasar/Vue.js
   - Comunica-se com servidor Coqui via HTTP
   - Porta: 8080
   - Recursos: 512MB-1GB RAM

## 🏗️ Pré-requisitos

### 1. Ferramentas Necessárias
- Docker
- AWS CLI configurado
- kubectl configurado
- Acesso ao cluster EKS
- Acesso ao ECR (Elastic Container Registry)

### 2. Arquivo de Voz de Referência
Você precisa de um arquivo de voz para clonagem:
- **Formato**: WAV (16-bit PCM, mono ou stereo)
- **Duração**: Mínimo 6 segundos (recomendado: 10-15s)
- **Idioma**: Português do Brasil
- **Qualidade**: Áudio limpo, sem ruído de fundo
- **Voz**: Feminina (ou a voz que deseja clonar)

**Localização do arquivo**: Tenha o arquivo pronto localmente (ex: `~/voice_reference.wav`)

## 🚀 Passo a Passo do Deploy

### Passo 1: Build e Push das Imagens Docker

#### 1.1. Fazer Login no ECR

```bash
# Fazer login no ECR
aws ecr get-login-password --region sa-east-1 | docker login --username AWS --password-stdin 961341521437.dkr.ecr.sa-east-1.amazonaws.com
```

#### 1.2. Build da Imagem do Servidor Coqui TTS

```bash
# Navegar para o diretório do projeto
cd /home/cristiano/projetos/saude/c-tv

# Build da imagem do servidor Coqui
docker build -f Dockerfile.coqui-server -t coqui-tts-server:latest .

# Tag para ECR
docker tag coqui-tts-server:latest 961341521437.dkr.ecr.sa-east-1.amazonaws.com/coqui-tts-server:latest

# Push para ECR
docker push 961341521437.dkr.ecr.sa-east-1.amazonaws.com/coqui-tts-server:latest
```

#### 1.3. Build da Imagem da Aplicação C-TV

```bash
# Build da imagem principal (sem TTS embutido)
docker build -f Dockerfile.prod -t c-tv:latest .

# Tag para ECR
docker tag c-tv:latest 961341521437.dkr.ecr.sa-east-1.amazonaws.com/c-tv:latest

# Push para ECR
docker push 961341521437.dkr.ecr.sa-east-1.amazonaws.com/c-tv:latest
```

### Passo 2: Criar Secret da Voz de Referência

```bash
# Criar secret com arquivo de voz de referência
kubectl create secret generic coqui-voice-reference \
  --from-file=reference_voice.wav=/caminho/para/seu/arquivo_de_voz.wav \
  --namespace c-tv
```

**IMPORTANTE**: Substitua `/caminho/para/seu/arquivo_de_voz.wav` pelo caminho real do seu arquivo de voz.

### Passo 3: Aplicar ConfigMap

```bash
# Aplicar ConfigMap com variáveis de ambiente
kubectl apply -f /home/cristiano/projetos/saude/k8s/c-tv/env-configmap.yaml
```

### Passo 4: Criar PersistentVolumeClaim (se ainda não existir)

```bash
# Verificar se o PVC já existe
kubectl get pvc audio-cache-pvc -n c-tv

# Se não existir, criar o PVC
kubectl apply -f /home/cristiano/projetos/saude/k8s/c-tv/audio-cache-pvc.yaml
```

### Passo 5: Deploy do Servidor Coqui TTS

```bash
# Aplicar deployment do servidor Coqui
kubectl apply -f /home/cristiano/projetos/saude/k8s/c-tv/coqui-deployment.yaml

# Aplicar service do servidor Coqui
kubectl apply -f /home/cristiano/projetos/saude/k8s/c-tv/coqui-service.yaml

# Verificar se o pod está rodando (aguardar ~3 minutos para carregar o modelo)
kubectl get pods -n c-tv -l app.kubernetes.io/component=coqui-tts

# Verificar logs do servidor Coqui
kubectl logs -f deployment/coqui-server -n c-tv
```

**Logs esperados**:
```
[Coqui Server] Carregando modelo XTTS-v2 em cpu...
[Coqui Server] Modelo carregado com sucesso!
[Coqui Server] Voz de referência: /app/voice_samples/reference_voice.wav
[Coqui Server] Servidor iniciado na porta 5000
```

### Passo 6: Deploy da Aplicação C-TV

```bash
# Aplicar deployment da aplicação principal
kubectl apply -f /home/cristiano/projetos/saude/k8s/c-tv/web-deployment.yaml

# Aplicar service da aplicação
kubectl apply -f /home/cristiano/projetos/saude/k8s/c-tv/web-service.yaml

# Verificar se o pod está rodando
kubectl get pods -n c-tv -l app.kubernetes.io/component=web

# Verificar logs da aplicação
kubectl logs -f deployment/web -n c-tv
```

### Passo 7: Configurar Ingress (se necessário)

```bash
# Aplicar ingress
kubectl apply -f /home/cristiano/projetos/saude/k8s/c-tv/web-ingress.yaml

# Verificar ingress
kubectl get ingress -n c-tv
```

## 🔍 Verificação e Testes

### Verificar Status dos Pods

```bash
# Ver todos os pods do namespace c-tv
kubectl get pods -n c-tv

# Ver detalhes de um pod específico
kubectl describe pod <pod-name> -n c-tv
```

### Testar Servidor Coqui TTS

```bash
# Port-forward para o servidor Coqui
kubectl port-forward svc/coqui-server 5000:5000 -n c-tv

# Em outro terminal, testar o endpoint de health
curl http://localhost:5000/health

# Testar síntese de voz (deve retornar JSON com sucesso)
curl -X POST http://localhost:5000/synthesize \
  -H "Content-Type: application/json" \
  -d '{
    "text": "Olá, este é um teste de síntese de voz",
    "output_path": "/tmp/test.wav",
    "language": "pt"
  }'
```

### Testar Aplicação C-TV

```bash
# Port-forward para a aplicação
kubectl port-forward svc/web-service 8080:8080 -n c-tv

# Em outro terminal, testar o endpoint de health
curl http://localhost:8080/health

# Acessar no navegador
open http://localhost:8080
```

## 🔄 ArgoCD - Deploy Automatizado

### Configurar ArgoCD Application

Se você estiver usando ArgoCD, configure a aplicação para sincronizar automaticamente:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: c-tv
  namespace: argocd
spec:
  project: default
  source:
    repoURL: <URL_DO_SEU_REPOSITORIO_GIT>
    targetRevision: HEAD
    path: k8s/c-tv
  destination:
    server: https://kubernetes.default.svc
    namespace: c-tv
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

### Sincronizar Manualmente via ArgoCD

```bash
# Sincronizar aplicação
argocd app sync c-tv

# Verificar status
argocd app get c-tv

# Ver logs de sincronização
argocd app logs c-tv
```

## 📊 Monitoramento

### Verificar Recursos Utilizados

```bash
# Ver uso de recursos dos pods
kubectl top pods -n c-tv

# Ver métricas do servidor Coqui
kubectl top pod -l app.kubernetes.io/component=coqui-tts -n c-tv
```

### Logs em Tempo Real

```bash
# Logs do servidor Coqui
kubectl logs -f deployment/coqui-server -n c-tv

# Logs da aplicação C-TV
kubectl logs -f deployment/web -n c-tv

# Logs de ambos simultaneamente
kubectl logs -f -l app.kubernetes.io/name=c-tv -n c-tv --all-containers=true
```

## 🔧 Troubleshooting

### Servidor Coqui não inicia

**Problema**: Pod do Coqui fica em CrashLoopBackOff

**Soluções**:
1. Verificar se o secret da voz de referência foi criado:
   ```bash
   kubectl get secret coqui-voice-reference -n c-tv
   ```

2. Verificar se o arquivo de voz está montado corretamente:
   ```bash
   kubectl exec -it deployment/coqui-server -n c-tv -- ls -lh /app/voice_samples/
   ```

3. Verificar logs de erro:
   ```bash
   kubectl logs deployment/coqui-server -n c-tv --previous
   ```

### Aplicação C-TV não consegue se comunicar com Coqui

**Problema**: Erros de conexão com servidor Coqui

**Soluções**:
1. Verificar se o service do Coqui está rodando:
   ```bash
   kubectl get svc coqui-server -n c-tv
   ```

2. Testar conectividade de dentro do pod da aplicação:
   ```bash
   kubectl exec -it deployment/web -n c-tv -- curl http://coqui-server:5000/health
   ```

3. Verificar variável de ambiente COQUI_SERVER_URL:
   ```bash
   kubectl exec -it deployment/web -n c-tv -- env | grep COQUI
   ```

### Modelo demora muito para carregar

**Problema**: Servidor Coqui demora mais de 3 minutos para ficar pronto

**Soluções**:
1. Aumentar `initialDelaySeconds` nos probes do `coqui-deployment.yaml`
2. Verificar recursos disponíveis no nó:
   ```bash
   kubectl describe node <node-name>
   ```

### Cache de áudio não está sendo compartilhado

**Problema**: PVC não está sendo montado corretamente

**Soluções**:
1. Verificar PVC:
   ```bash
   kubectl get pvc audio-cache-pvc -n c-tv
   ```

2. Verificar se ambos os pods estão no mesmo nó (requisito para RWO):
   ```bash
   kubectl get pods -n c-tv -o wide
   ```

## 🔐 Segurança

### Secret da Voz de Referência

**IMPORTANTE**: O secret contém a voz de referência e deve ser protegido:

- Não commitar no Git
- Fazer backup do secret:
  ```bash
  kubectl get secret coqui-voice-reference -n c-tv -o yaml > backup-secret.yaml
  ```
- Armazenar backup em local seguro (ex: AWS Secrets Manager)

### ConfigMap

O ConfigMap (`env-configmap.yaml`) pode ser commitado no Git, pois:
- Não contém informações sensíveis (apenas configurações)
- É gerenciado pelo ArgoCD via GitOps

## 📝 Variáveis de Ambiente

Todas as variáveis de ambiente estão definidas em:
- **Arquivo**: `/home/cristiano/projetos/saude/k8s/c-tv/env-configmap.yaml`
- **ConfigMap**: `env` (namespace `c-tv`)

### Variáveis Principais

#### Aplicação C-TV
- `CTV_ENV`: Ambiente (prod)
- `CTV_SSL`: SSL habilitado (FALSE - Ingress faz TLS termination)
- `CTV_PORT`: Porta do servidor (8080)
- `TTS_PROVIDER`: Provider de TTS (coqui-http)
- `COQUI_SERVER_URL`: URL do servidor Coqui (http://coqui-server:5000)

#### Servidor Coqui TTS
- `FLASK_PORT`: Porta do Flask (5000)
- `COQUI_REFERENCE_AUDIO`: Caminho do arquivo de voz (/app/voice_samples/reference_voice.wav)
- `COQUI_TEMP_DIR`: Diretório de cache (/app/cache_audio)
- `COQUI_TOS_AGREED`: Aceitar termos do Coqui (1)

## 🎯 Resumo dos Comandos

```bash
# 1. Login no ECR
aws ecr get-login-password --region sa-east-1 | docker login --username AWS --password-stdin 961341521437.dkr.ecr.sa-east-1.amazonaws.com

# 2. Build e push das imagens
cd /home/cristiano/projetos/saude/c-tv
docker build -f Dockerfile.coqui-server -t coqui-tts-server:latest .
docker tag coqui-tts-server:latest 961341521437.dkr.ecr.sa-east-1.amazonaws.com/coqui-tts-server:latest
docker push 961341521437.dkr.ecr.sa-east-1.amazonaws.com/coqui-tts-server:latest

docker build -f Dockerfile.prod -t c-tv:latest .
docker tag c-tv:latest 961341521437.dkr.ecr.sa-east-1.amazonaws.com/c-tv:latest
docker push 961341521437.dkr.ecr.sa-east-1.amazonaws.com/c-tv:latest

# 3. Criar secret da voz
kubectl create secret generic coqui-voice-reference \
  --from-file=reference_voice.wav=/caminho/para/arquivo_de_voz.wav \
  --namespace c-tv

# 4. Aplicar manifests
kubectl apply -f /home/cristiano/projetos/saude/k8s/c-tv/env-configmap.yaml
kubectl apply -f /home/cristiano/projetos/saude/k8s/c-tv/coqui-deployment.yaml
kubectl apply -f /home/cristiano/projetos/saude/k8s/c-tv/coqui-service.yaml
kubectl apply -f /home/cristiano/projetos/saude/k8s/c-tv/web-deployment.yaml
kubectl apply -f /home/cristiano/projetos/saude/k8s/c-tv/web-service.yaml

# 5. Verificar deployment
kubectl get pods -n c-tv
kubectl logs -f deployment/coqui-server -n c-tv
kubectl logs -f deployment/web -n c-tv
```

## 📚 Referências

- **Projeto C-TV**: `/home/cristiano/projetos/saude/c-tv/`
- **Manifests Kubernetes**: `/home/cristiano/projetos/saude/k8s/c-tv/`
- **Dockerfile Servidor Coqui**: `/home/cristiano/projetos/saude/c-tv/Dockerfile.coqui-server`
- **Dockerfile App C-TV**: `/home/cristiano/projetos/saude/c-tv/Dockerfile.prod`
- **CLAUDE.md**: `/home/cristiano/projetos/saude/c-tv/CLAUDE.md`
