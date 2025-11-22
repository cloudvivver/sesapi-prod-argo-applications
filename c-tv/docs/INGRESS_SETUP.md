# Configuração do Ingress HTTPS para C-TV

Este guia descreve como configurar o acesso HTTPS ao C-TV via `https://c-tv.saude.pi.gov.br`.

## Pré-requisitos

1. **NGINX Ingress Controller** instalado no cluster
2. **cert-manager** instalado no cluster (para certificados SSL automáticos)
3. **DNS configurado**: `c-tv.saude.pi.gov.br` apontando para o IP do Load Balancer do Ingress

## 1. Verificar Pré-requisitos

### Verificar NGINX Ingress Controller

```bash
# Ver se o NGINX Ingress está instalado
kubectl get pods -n ingress-nginx

# Ver o serviço do NGINX (pega o EXTERNAL-IP)
kubectl get svc -n ingress-nginx
```

O `EXTERNAL-IP` do serviço `ingress-nginx-controller` deve estar configurado no DNS.

### Verificar cert-manager

```bash
# Ver se o cert-manager está instalado
kubectl get pods -n cert-manager

# Ver versão
kubectl get deployment -n cert-manager cert-manager -o yaml | grep image:
```

Se não estiver instalado:
```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml
```

## 2. Configurar DNS

Configure o DNS `c-tv.saude.pi.gov.br` para apontar para o IP externo do NGINX Ingress:

```bash
# Pegar o IP externo do Ingress
kubectl get svc -n ingress-nginx ingress-nginx-controller

# Exemplo de registro DNS (A Record):
# c-tv.saude.pi.gov.br  →  34.95.123.45  (EXTERNAL-IP do Ingress)
```

**Teste DNS:**
```bash
nslookup c-tv.saude.pi.gov.br
# Ou
dig c-tv.saude.pi.gov.br
```

## 3. Aplicar ClusterIssuer do Let's Encrypt

O ClusterIssuer é usado pelo cert-manager para emitir certificados SSL:

```bash
# Aplicar o ClusterIssuer
kubectl apply -f cert-manager-issuer.yaml

# Verificar se foi criado
kubectl get clusterissuer
kubectl describe clusterissuer letsencrypt-http
```

**Nota:** O arquivo inclui 2 issuers:
- `letsencrypt-http` - **Produção** (usar este)
- `letsencrypt-staging` - Staging/testes (limite mais alto de requisições)

## 4. Aplicar o Ingress

```bash
# Aplicar o Ingress
kubectl apply -f web-ingress.yaml

# Verificar status
kubectl get ingress -n c-tv
kubectl describe ingress web-ingress -n c-tv
```

## 5. Verificar Certificado SSL

O cert-manager vai automaticamente:
1. Detectar o Ingress com annotation `cert-manager.io/cluster-issuer`
2. Criar um Certificate resource
3. Fazer o desafio HTTP-01 com Let's Encrypt
4. Armazenar o certificado no Secret `c-tv-tls`

**Verificar Certificate:**
```bash
# Ver certificado
kubectl get certificate -n c-tv

# Ver detalhes (status, eventos)
kubectl describe certificate c-tv-tls -n c-tv

# Ver secret do certificado
kubectl get secret c-tv-tls -n c-tv
```

**Status esperado:**
```
NAME        READY   SECRET      AGE
c-tv-tls    True    c-tv-tls    5m
```

**Se READY = False:**
```bash
# Ver logs do cert-manager
kubectl logs -n cert-manager deployment/cert-manager

# Ver CertificateRequest
kubectl get certificaterequest -n c-tv
kubectl describe certificaterequest -n c-tv

# Ver desafio HTTP-01
kubectl get challenge -n c-tv
kubectl describe challenge -n c-tv
```

## 6. Testar Acesso HTTPS

```bash
# Teste básico
curl -I https://c-tv.saude.pi.gov.br/health

# Verificar certificado
curl -vI https://c-tv.saude.pi.gov.br 2>&1 | grep -E "SSL|certificate"

# Ou usar openssl
openssl s_client -connect c-tv.saude.pi.gov.br:443 -servername c-tv.saude.pi.gov.br
```

Acesse no navegador: **https://c-tv.saude.pi.gov.br**

## 7. Troubleshooting

### Certificado não é emitido (READY = False)

**Problema 1: DNS não está resolvendo**
```bash
# Verificar DNS
nslookup c-tv.saude.pi.gov.br

# Testar do cluster
kubectl run -it --rm debug --image=curlimages/curl --restart=Never -- \
  nslookup c-tv.saude.pi.gov.br
```

**Problema 2: Desafio HTTP-01 falhando**
```bash
# Ver desafio
kubectl get challenge -n c-tv
kubectl describe challenge -n c-tv

# Testar endpoint do desafio manualmente
# O Let's Encrypt vai acessar: http://c-tv.saude.pi.gov.br/.well-known/acme-challenge/<token>

# Ver logs do NGINX Ingress
kubectl logs -n ingress-nginx deployment/ingress-nginx-controller
```

**Problema 3: Limite de rate do Let's Encrypt**
- Produção: 50 certificados/semana por domínio registrado
- Se atingir limite, use `letsencrypt-staging` temporariamente

Trocar para staging:
```bash
# Editar ingress
kubectl edit ingress web-ingress -n c-tv

# Alterar annotation:
# cert-manager.io/cluster-issuer: letsencrypt-staging

# Deletar certificado antigo
kubectl delete certificate c-tv-tls -n c-tv
kubectl delete secret c-tv-tls -n c-tv
```

### WebSocket não funciona

**Verificar annotations do Ingress:**
```yaml
nginx.ingress.kubernetes.io/websocket-services: "web-service"
nginx.ingress.kubernetes.io/proxy-buffering: "off"
```

**Testar WebSocket:**
```bash
# Instalar wscat (se não tiver)
npm install -g wscat

# Testar conexão WebSocket
wscat -c wss://c-tv.saude.pi.gov.br/ws?t9f2s_o&2
```

### Timeouts em requisições longas (TTS)

As configurações de timeout já estão no Ingress:
```yaml
nginx.ingress.kubernetes.io/proxy-connect-timeout: "300"
nginx.ingress.kubernetes.io/proxy-send-timeout: "300"
nginx.ingress.kubernetes.io/proxy-read-timeout: "300"
```

Se ainda houver timeout, aumentar os valores.

### Erro "default backend - 404"

Significa que o Ingress não encontrou o Service:

```bash
# Verificar se o Service existe
kubectl get svc web-service -n c-tv

# Verificar se tem pods rodando
kubectl get pods -n c-tv

# Verificar selector do Service
kubectl get svc web-service -n c-tv -o yaml | grep -A5 selector

# Verificar labels dos pods
kubectl get pods -n c-tv --show-labels
```

## 8. Renovação Automática

O cert-manager renova automaticamente certificados 30 dias antes do vencimento.

**Forçar renovação manual:**
```bash
# Deletar o secret
kubectl delete secret c-tv-tls -n c-tv

# O cert-manager vai recriar automaticamente
kubectl get certificate -n c-tv -w
```

## 9. Monitoramento

### Verificar validade do certificado

```bash
# Ver data de expiração
kubectl get certificate c-tv-tls -n c-tv -o jsonpath='{.status.notAfter}'

# Ou via OpenSSL
echo | openssl s_client -connect c-tv.saude.pi.gov.br:443 2>/dev/null | \
  openssl x509 -noout -dates
```

### Logs importantes

```bash
# Logs do cert-manager
kubectl logs -n cert-manager deployment/cert-manager -f

# Logs do NGINX Ingress
kubectl logs -n ingress-nginx deployment/ingress-nginx-controller -f

# Ver eventos do namespace
kubectl get events -n c-tv --sort-by='.lastTimestamp'
```

## 10. Configuração de Segurança Adicional

### Redirecionar HTTP → HTTPS

Já configurado via annotation:
```yaml
nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
```

### HSTS (HTTP Strict Transport Security)

Adicionar ao Ingress:
```yaml
annotations:
  nginx.ingress.kubernetes.io/hsts: "true"
  nginx.ingress.kubernetes.io/hsts-max-age: "31536000"
  nginx.ingress.kubernetes.io/hsts-include-subdomains: "true"
```

### Rate Limiting

Adicionar ao Ingress:
```yaml
annotations:
  nginx.ingress.kubernetes.io/limit-rps: "100"
  nginx.ingress.kubernetes.io/limit-connections: "10"
```

## Resumo da Configuração

```
Internet
   │
   │ DNS: c-tv.saude.pi.gov.br → EXTERNAL-IP
   │
   ▼
┌─────────────────────────────┐
│  Load Balancer (cloud)       │
│  EXTERNAL-IP: x.x.x.x        │
└──────────────┬───────────────┘
               │
               ▼
┌─────────────────────────────┐
│  NGINX Ingress Controller    │
│  Namespace: ingress-nginx    │
│  - SSL Termination           │
│  - WebSocket Upgrade         │
└──────────────┬───────────────┘
               │
               ▼
┌─────────────────────────────┐
│  Ingress: web-ingress        │
│  Host: c-tv.saude.pi.gov.br  │
│  TLS: c-tv-tls (Let's Encrypt)│
└──────────────┬───────────────┘
               │
               ▼
┌─────────────────────────────┐
│  Service: web-service        │
│  ClusterIP:80 → Pod:8080     │
└──────────────┬───────────────┘
               │
               ▼
┌─────────────────────────────┐
│  Deployment: web             │
│  Pods: c-tv backend (3x)     │
└─────────────────────────────┘
```

## Links Úteis

- [NGINX Ingress Controller](https://kubernetes.github.io/ingress-nginx/)
- [cert-manager](https://cert-manager.io/)
- [Let's Encrypt Rate Limits](https://letsencrypt.org/docs/rate-limits/)
