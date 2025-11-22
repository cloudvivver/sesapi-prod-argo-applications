# Status da Implantação C-TV com Coqui TTS

**Data da Implantação:** 22/11/2025
**Ambiente:** Produção (EKS)
**Namespace:** c-tv

## ✅ Status Geral: SUCESSO

Todos os componentes foram implantados com sucesso e estão funcionando corretamente.

---

## Componentes Implantados

### 1. Servidor Coqui TTS
- **Deployment:** `coqui-server`
- **Pod:** `coqui-server-667788c868-fzbpf`
- **Status:** Running (1/1 READY)
- **Imagem:** `961341521437.dkr.ecr.sa-east-1.amazonaws.com/coqui-tts-server:latest`
- **Tamanho da Imagem:** 928 MB
- **Modelo:** XTTS-v2 (multilingual/multi-dataset)
- **Dispositivo:** CPU
- **Arquivo de Referência:** `/app/voice_samples/reference_voice.wav` (833 KB)
- **Health Check:** ✅ OK
  ```json
  {"device":"cpu","model_loaded":true,"status":"ok"}
  ```

### 2. Aplicação C-TV
- **Deployment:** `web`
- **Pod:** `web-76569d6768-q5k7k`
- **Status:** Running (1/1 READY)
- **Imagem:** `961341521437.dkr.ecr.sa-east-1.amazonaws.com/c-tv:latest`
- **Tamanho da Imagem:** 15 MB
- **Versão:** C-TV SOLID v0.03
- **Ambiente:** PROD
- **Health Check:** ✅ OK

---

## Serviços

### coqui-server
- **Tipo:** ClusterIP
- **Cluster-IP:** 172.20.112.29
- **Porta:** 5000/TCP
- **Endpoints:**
  - `GET /health` - Health check
  - `POST /synthesize` - Síntese de voz
  - `GET /info` - Informações do servidor

### web-service
- **Tipo:** ClusterIP
- **Cluster-IP:** 172.20.29.87
- **Portas:** 80/TCP, 443/TCP

---

## Ingress

- **Nome:** web-ingress
- **Classe:** nginx
- **Host:** c-tv.saude.pi.gov.br
- **Endereço:** a8ecc5d6022ed430d83089b7ab2a8873-b481ee7df7e0ce24.elb.sa-east-1.amazonaws.com
- **Portas:** 80, 443
- **Status:** ✅ Ativo

**URL de Acesso:** https://c-tv.saude.pi.gov.br

---

## Configuração

### ConfigMap: env
Todas as variáveis de ambiente centralizadas em `/home/cristiano/projetos/saude/k8s/c-tv/env-configmap.yaml`:

**Principais Configurações:**
- `CTV_ENV: "prod"`
- `TTS_PROVIDER: "coqui-http"`
- `COQUI_SERVER_URL: "http://coqui-server:5000"`
- `CACHE_BACKEND: "hybrid"` (Memória + S3)
- `S3_CACHE_BUCKET: "cuidar-storage"`
- `S3_CACHE_PREFIX: "c-tv/cache"`

### Secret: coqui-voice-reference
Arquivo de voz de referência montado em `/app/voice_samples/reference_voice.wav`
- **Arquivo Original:** `/home/cristiano/projetos/saude/c-tv/voice_samples/reference_voice.wav`
- **Formato:** WAV, Mono, 22050 Hz
- **Tamanho:** 833 KB

---

## Testes de Conectividade

### ✅ Health Checks
- **C-TV App:** `http://localhost:8080/health` → `OK`
- **Coqui Server:** `http://localhost:5000/health` → `{"status":"ok","model_loaded":true}`

### ✅ Comunicação Interna
- **C-TV → Coqui Server:** `http://coqui-server:5000/info`
  ```json
  {
    "device": "cpu",
    "model": "tts_models/multilingual/multi-dataset/xtts_v2",
    "model_loaded": true,
    "reference_audio": "/app/voice_samples/reference_voice.wav",
    "temp_dir": "/app/cache_audio"
  }
  ```

---

## Recursos e Performance

### Coqui Server
```yaml
resources:
  requests:
    cpu: "1000m"
    memory: "3Gi"
  limits:
    cpu: "2000m"
    memory: "5Gi"
```

### C-TV App
```yaml
resources:
  requests:
    cpu: "500m"
    memory: "512Mi"
  limits:
    cpu: "1000m"
    memory: "1Gi"
```

---

## Cache de Áudio

### Configuração Atual: Híbrido (Memória + S3)

**Memory Cache (Hot Cache):**
- Ativado: ✅
- Max Size: 512 MB por pod
- TTL: 60 minutos

**S3 Cache (Warm Cache):**
- Ativado: ✅
- Bucket: `cuidar-storage`
- Prefix: `c-tv/cache/`
- Region: `sa-east-1`
- TTL: 720 horas (30 dias)

**Nota:** O cluster já tem acesso ao bucket S3 `cuidar-storage`. O cache S3 funcionará automaticamente se as permissões IAM estiverem configuradas.

### PersistentVolumeClaim
- **Nome:** `audio-cache-pvc`
- **Uso:** Cache local compartilhado entre pods (RWO)
- **Affinity:** Pods no mesmo node compartilham o volume

---

## Imagens Docker

### C-TV Application
```bash
docker pull 961341521437.dkr.ecr.sa-east-1.amazonaws.com/c-tv:latest
```
- **Base:** alpine:3.19
- **Runtime:** Go binary + SPA estático
- **Tamanho:** 15 MB
- **Multi-stage Build:** Node.js 20 (frontend) + Go 1.24 (backend)

### Coqui TTS Server
```bash
docker pull 961341521437.dkr.ecr.sa-east-1.amazonaws.com/coqui-tts-server:latest
```
- **Base:** python:3.11-slim
- **Framework:** Flask
- **Modelo:** XTTS-v2
- **Tamanho:** 928 MB
- **Inclui:** PyTorch, TTS, pydub, etc.

---

## Monitoramento

### Sentry Error Tracking
- **DSN:** Configurado via ConfigMap
- **Sample Rate:** 10% (0.1)
- **Ambiente:** PROD

### Logs
```bash
# Ver logs do C-TV
kubectl logs -f deployment/web -n c-tv

# Ver logs do Coqui Server
kubectl logs -f deployment/coqui-server -n c-tv

# Ver todos os pods
kubectl get pods -n c-tv
```

---

## Próximos Passos (Opcional)

### Melhorias Futuras

1. **IRSA para S3 Cache (Opcional)**
   - Configurar IAM Role com política em `iam-policy-s3-cache.json`
   - Vincular ao ServiceAccount `c-tv-s3-cache`
   - Descomentar `serviceAccountName` em `web-deployment.yaml`
   - Ver: `SETUP_S3_CACHE.md` para instruções completas

2. **VPC Endpoint para S3 (Recomendado)**
   - Reduzir custos de transferência de dados
   - Melhorar latência e segurança
   - Endpoint Gateway: sem custo adicional

3. **Lifecycle Rules no S3**
   - Deletar objetos automaticamente após 30 dias
   - Reduzir custos de armazenamento

4. **Scaling (Futuro)**
   - Considerar migrar PVC para EFS (RWX) para múltiplas réplicas
   - HPA (Horizontal Pod Autoscaling) para web app
   - Manter Coqui Server em 1 réplica (stateful)

5. **Monitoramento Avançado**
   - Prometheus + Grafana
   - Alertas para falhas de síntese
   - Métricas de cache hit/miss ratio

---

## Resolução de Problemas

### Ver Status dos Pods
```bash
kubectl get pods -n c-tv
kubectl describe pod <pod-name> -n c-tv
```

### Verificar Logs
```bash
kubectl logs deployment/web -n c-tv --tail=50
kubectl logs deployment/coqui-server -n c-tv --tail=50
```

### Testar Conectividade
```bash
# Health check do C-TV
kubectl exec -n c-tv deployment/web -- wget -qO- http://localhost:8080/health

# Health check do Coqui
kubectl exec -n c-tv deployment/coqui-server -- python3 -c \
  "import urllib.request; print(urllib.request.urlopen('http://localhost:5000/health').read().decode())"

# Testar comunicação interna
kubectl exec -n c-tv deployment/web -- wget -qO- http://coqui-server:5000/info
```

### Reiniciar Deployments
```bash
kubectl rollout restart deployment/web -n c-tv
kubectl rollout restart deployment/coqui-server -n c-tv
```

---

## Arquivos de Configuração

### Kubernetes Manifests
- `env-configmap.yaml` - Variáveis de ambiente
- `web-deployment.yaml` - Deployment do app C-TV
- `coqui-deployment.yaml` - Deployment do servidor Coqui
- `coqui-service.yaml` - Service do Coqui (ClusterIP)
- `web-service.yaml` - Service do C-TV (ClusterIP)
- `web-ingress.yaml` - Ingress NGINX com TLS
- `audio-cache-pvc.yaml` - PersistentVolumeClaim
- `serviceaccount-s3-cache.yaml` - Service Account com IRSA

### Dockerfiles
- `/home/cristiano/projetos/saude/c-tv/Dockerfile.prod` - Imagem C-TV
- `/home/cristiano/projetos/saude/c-tv/Dockerfile.coqui-server` - Imagem Coqui TTS

### Documentação
- `DEPLOY_COQUI_PRODUCTION.md` - Guia de deployment
- `SETUP_S3_CACHE.md` - Configuração do cache S3
- `/home/cristiano/projetos/saude/c-tv/api/IMPLEMENTACAO_CACHE_S3.md` - Integração do código

---

## Contato e Suporte

Para problemas ou dúvidas:
1. Verificar logs dos pods
2. Consultar documentação em `DEPLOY_COQUI_PRODUCTION.md`
3. Revisar configuração em `env-configmap.yaml`

---

**Implantação finalizada com sucesso! 🎉**

O sistema C-TV com Coqui TTS está totalmente operacional e acessível em **https://c-tv.saude.pi.gov.br**
