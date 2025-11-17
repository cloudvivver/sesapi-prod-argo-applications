# cetea-pi - Configuração Kubernetes

## 📋 Informações do Ambiente

- **Namespace**: `cetea-pi`
- **Aplicação**: cetea
- **Domínio**: `cetea.saude.pi.gov.br`
- **Database**: `tenant_cetea_db`
- **Ambiente**: Production

## 🗄️ Banco de Dados (RDS Proxy)

- **Host**: `proxy-db-viverdb.proxy-cb8m6qcy2cyh.sa-east-1.rds.amazonaws.com`
- **Port**: `5432`
- **Database**: `tenant_cetea_db`
- **User**: `postgres`
- **SSL**: `require` (obrigatório)
- **Connection Pool**: 20 conexões

## 🚀 Deploy

### Ordem de aplicação:

```bash
# 1. Namespace
kubectl apply -f namespace.yaml

# 2. Secrets (contém credenciais sensíveis)
kubectl apply -f secrets.yaml

# 3. ConfigMap
kubectl apply -f env-configmap.yaml

# 4. PVC (EBS gp3 - dynamic provisioning)
kubectl apply -f pvc.yaml

# 5. Redis
kubectl apply -f redis-configmap.yaml
kubectl apply -f redis-deployment.yaml
kubectl apply -f redis-service.yaml

# 6. Services
kubectl apply -f web-service.yaml

# 7. Deployments
kubectl apply -f web-deployment.yaml
kubectl apply -f sidekiq-deployment.yaml

# 8. Ingress
kubectl apply -f web-ingress.yaml
```

### Ou aplicar tudo de uma vez:

```bash
kubectl apply -f .
```

## 🔍 Verificar Status

```bash
# Ver todos os recursos
kubectl get all,pvc,ingress -n cetea-pi

# Ver pods
kubectl get pods -n cetea-pi

# Ver logs
kubectl logs -n cetea-pi deployment/cetea -f
kubectl logs -n cetea-pi deployment/sidekiq -f

# Port-forward para testar localmente
kubectl port-forward -n cetea-pi deployment/cetea 3030:3000
# Acesse: http://localhost:3030
```

## 🌐 DNS

Configure o DNS conforme instruções em `DNS.txt`:

```
Tipo: CNAME
Nome: cetea.saude.pi.gov.br
Aponta para: a8ecc5d6022ed430d83089b7ab2a8873-b481ee7df7e0ce24.elb.sa-east-1.amazonaws.com
TTL: 300
```

## 🔧 Pós-Deploy

Após o deploy, adicione PRIMARY KEY na tabela login_sessao:

```bash
kubectl exec -n cetea-pi deployment/cetea -- bundle exec rails runner \
  "ActiveRecord::Base.connection.execute('ALTER TABLE login_sessao ADD PRIMARY KEY (id);'); \
   puts 'Primary key added successfully!'"
```

## 📦 Imagem Docker

- **ECR**: `961341521437.dkr.ecr.sa-east-1.amazonaws.com/saude-publica-web:latest`

## 💾 Armazenamento

- **StorageClass**: `gp3` (AWS EBS)
- **Capacity**: 100Gi (principal) + 20Gi (backup)
- **Access Mode**: ReadWriteOnce (RWO)

## 🔐 Secrets

Os seguintes secrets são gerenciados via Kubernetes Secret:
- DATABASE_PASSWORD
- DATABASE_USERNAME
- PGWEB_DATABASE_URL
- SECRET_KEY_BASE
- HIDRA_TOKEN
- SENTRY_URL

## 📝 Arquivos

- `namespace.yaml` - Definição do namespace
- `env-configmap.yaml` - Configurações públicas
- `secrets.yaml` - Credenciais sensíveis
- `pv.yaml` - Documentação do PV (auto-criado)
- `pvc.yaml` - Persistent Volume Claim (EBS gp3)
- `web-deployment.yaml` - Deployment da aplicação web
- `sidekiq-deployment.yaml` - Deployment do Sidekiq
- `web-service.yaml` - Service da aplicação
- `web-ingress.yaml` - Ingress (nginx)
- `redis-*.yaml` - Configuração do Redis
- `DNS.txt` - Instruções para configurar DNS
- `README.md` - Este arquivo

## ✅ Checklist de Deploy

- [ ] Configurar DNS (veja DNS.txt)
- [ ] Aplicar todos os manifestos
- [ ] Verificar pods estão Running
- [ ] Adicionar PRIMARY KEY na tabela login_sessao
- [ ] Testar acesso via domain
- [ ] Verificar logs para erros
- [ ] Testar login na aplicação

---

**Última atualização**: 2025-11-17
**Gerado automaticamente via Claude Code**
