# Configuração do Coqui TTS no Kubernetes

Este guia descreve como configurar o C-TV com Coqui XTTS-v2 no Kubernetes.

## ⚠️ Configuração Atual (Sem EFS)

A configuração atual **NÃO usa EFS** (aguardando aprovação). Isso significa:

- ✅ Funciona com **PVC padrão** (gp2/gp3 - ReadWriteOnce)
- ⚠️ Apenas **1 réplica** do backend (sem alta disponibilidade)
- ⚠️ Pods backend e Coqui Server **devem rodar no mesmo nó** (Pod Affinity configurada)
- ⚠️ Strategy: **Recreate** (breve downtime durante atualizações)

**Quando o EFS for aprovado**, veja `MIGRAR_PARA_EFS.md` para upgrade para:
- ✅ **3 réplicas** do backend (alta disponibilidade)
- ✅ Cache compartilhado entre pods
- ✅ **RollingUpdate** (zero downtime)

## Pré-requisitos

1. **Arquivo de voz de referência** (6+ segundos, pt-BR feminina)
   - Formato: WAV ou MP3
   - Duração: 10-15 segundos recomendado
   - Idioma: Português brasileiro
   - Qualidade: Gravação profissional sem ruído
   - Localização: `./voice_samples/reference_voice.wav`

## 1. Criar o Secret da Voz de Referência

Antes de aplicar os manifestos, você precisa criar um Kubernetes Secret com o arquivo de voz:

```bash
# Navegar até o diretório do projeto
cd /home/cristiano/projetos/saude/c-tv

# Criar o secret a partir do arquivo de voz
kubectl create secret generic coqui-voice-reference \
  --from-file=reference_voice.wav=./voice_samples/reference_voice.wav \
  --namespace=c-tv

# Verificar se o secret foi criado
kubectl get secret coqui-voice-reference -n c-tv
kubectl describe secret coqui-voice-reference -n c-tv
```

## 2. Construir e Publicar a Imagem do Coqui Server

```bash
# Navegar até o diretório do projeto
cd /home/cristiano/projetos/saude/c-tv

# Build da imagem do Coqui Server
docker build -f Dockerfile.coqui-server -t coqui-tts-server:latest .

# Tag para ECR
docker tag coqui-tts-server:latest 961341521437.dkr.ecr.sa-east-1.amazonaws.com/coqui-tts-server:latest

# Login no ECR (se necessário)
aws ecr get-login-password --region sa-east-1 | \
  docker login --username AWS --password-stdin 961341521437.dkr.ecr.sa-east-1.amazonaws.com

# Push para ECR
docker push 961341521437.dkr.ecr.sa-east-1.amazonaws.com/coqui-tts-server:latest
```

## 3. Aplicar os Manifestos do Kubernetes

Na ordem correta:

```bash
# 1. Namespace (se ainda não existe)
kubectl apply -f namespace.yaml

# 2. ConfigMap com variáveis de ambiente
kubectl apply -f env-configmap.yaml

# 3. PVC para cache de áudio (EFS)
kubectl apply -f audio-cache-pvc.yaml

# 4. Service do Coqui Server (interno)
kubectl apply -f coqui-service.yaml

# 5. Deployment do Coqui Server
kubectl apply -f coqui-deployment.yaml

# 6. Deployment do Backend C-TV
kubectl apply -f web-deployment.yaml

# 7. Service do Backend (se ainda não existe)
kubectl apply -f web-service.yaml

# 8. Ingress (se ainda não existe)
kubectl apply -f web-ingress.yaml
```

## 4. Verificar o Deploy

### Verificar Pods

```bash
# Ver todos os pods do namespace c-tv
kubectl get pods -n c-tv -w

# Logs do Coqui Server (pode demorar ~5 min para carregar modelo)
kubectl logs -f deployment/coqui-server -n c-tv

# Logs do Backend
kubectl logs -f deployment/web -n c-tv
```

### Verificar Serviços

```bash
# Ver services
kubectl get svc -n c-tv

# Testar conectividade interna (de dentro de um pod backend)
kubectl exec -it deployment/web -n c-tv -- wget -O- http://coqui-server:5000/health
```

### Verificar PVC

```bash
# Ver PVC e se está bound
kubectl get pvc -n c-tv

# Ver uso do volume
kubectl exec -it deployment/web -n c-tv -- df -h /app/cache_audio
```

## 5. Testar TTS

### Teste Manual via Port-Forward

```bash
# Port-forward para o backend
kubectl port-forward -n c-tv deployment/web 8080:8080

# Em outro terminal, testar endpoint TTS
curl -v 'http://localhost:8080/speak?key=e38cade885ddd37895267ba0ff210551&texto=SENHA%20TESTE%20123&voz=coqui' \
  -o /tmp/test_tts.wav

# Verificar se o arquivo é áudio válido
file /tmp/test_tts.wav
```

### Verificar Logs

```bash
# Ver logs do Coqui Server durante síntese
kubectl logs -f deployment/coqui-server -n c-tv | grep -E "Sintetizando|Síntese concluída"

# Ver logs do Backend
kubectl logs -f deployment/web -n c-tv | grep -E "CoquiHTTP|TTS"
```

## 6. Troubleshooting

### Pod do Coqui não inicia

```bash
# Ver eventos
kubectl describe pod -l app.kubernetes.io/component=coqui-tts -n c-tv

# Verificar se o secret existe
kubectl get secret coqui-voice-reference -n c-tv

# Verificar se o arquivo de voz está no secret
kubectl get secret coqui-voice-reference -n c-tv -o jsonpath='{.data.reference_voice\.wav}' | base64 -d | wc -c
```

### Erro de permissão no cache

```bash
# Verificar permissões do volume
kubectl exec -it deployment/web -n c-tv -- ls -la /app/cache_audio

# Se necessário, corrigir permissões
kubectl exec -it deployment/coqui-server -n c-tv -c coqui-tts -- chown -R 1000:1000 /app/cache_audio
```

### TTS retorna erro 500

```bash
# Verificar conectividade entre pods
kubectl exec -it deployment/web -n c-tv -- nc -zv coqui-server 5000

# Verificar logs detalhados
kubectl logs -f deployment/web -n c-tv
kubectl logs -f deployment/coqui-server -n c-tv
```

## 7. Atualizar Imagens

### Atualizar Backend

```bash
# Build local
docker-compose -f docker-compose.coqui-http.yml build c-tv-backend

# Tag e push
docker tag c-tv:latest 961341521437.dkr.ecr.sa-east-1.amazonaws.com/c-tv:latest
docker push 961341521437.dkr.ecr.sa-east-1.amazonaws.com/c-tv:latest

# Restart deployment
kubectl rollout restart deployment/web -n c-tv
kubectl rollout status deployment/web -n c-tv
```

### Atualizar Coqui Server

```bash
# Build local
docker-compose -f docker-compose.coqui-http.yml build coqui-server

# Tag e push
docker tag coqui-tts-server:latest 961341521437.dkr.ecr.sa-east-1.amazonaws.com/coqui-tts-server:latest
docker push 961341521437.dkr.ecr.sa-east-1.amazonaws.com/coqui-tts-server:latest

# Restart deployment
kubectl rollout restart deployment/coqui-server -n c-tv
kubectl rollout status deployment/coqui-server -n c-tv
```

## 8. Voltar para AWS Polly (Futuro)

Para voltar a usar AWS Polly, basta:

1. Editar `env-configmap.yaml`:
   ```yaml
   TTS_PROVIDER: "polly"
   # Comentar ou remover COQUI_SERVER_URL
   ```

2. Aplicar mudança:
   ```bash
   kubectl apply -f env-configmap.yaml
   kubectl rollout restart deployment/web -n c-tv
   ```

3. Opcionalmente, escalar o Coqui Server para 0:
   ```bash
   kubectl scale deployment/coqui-server -n c-tv --replicas=0
   ```

## Recursos

### Coqui Server
- **Réplicas**: 1 (stateful)
- **CPU**: 1-2 cores
- **RAM**: 3-5 GB (modelo XTTS-v2 é pesado)
- **Disco**: Cache compartilhado via PVC RWO

### Backend C-TV
- **Réplicas**: 1 (aguardando EFS para escalar para 3)
- **CPU**: 0.5-1 core
- **RAM**: 512MB-1GB
- **Disco**: Cache compartilhado via PVC RWO
- **Affinity**: Roda no mesmo nó que Coqui Server (PVC RWO)

### Cache (PVC)
- **Tamanho**: 10GB
- **Modo**: ReadWriteOnce (gp2/gp3 padrão)
- **StorageClass**: Padrão do cluster (geralmente gp2 ou gp3)
- **Compartilhado**: Entre backend e Coqui Server (mesmo nó)
- **TTL**: 10 minutos (configurável via CACHE_TTL_MINUTES)
- **Custo**: ~$1/mês (10GB gp3)
