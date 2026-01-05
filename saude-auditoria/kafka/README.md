# Apache Kafka - Sistema Nervoso Central da Auditoria

Apache Kafka 7.6.0 (Confluent Platform) configurado para ser o **coração da arquitetura de auditoria** da Saúde Pública do Piauí.

## 🧠 Papel do Kafka

> **Kafka é o "sistema nervoso central" da auditoria: ele desacopla produtores de consumidores no tempo, na escala e na evolução.**

Kafka **NÃO é**:
- ❌ Banco de dados
- ❌ Fila simples (SQS, RabbitMQ)
- ❌ Sidekiq distribuído

Kafka **É**:
- ✅ Log distribuído imutável
- ✅ Buffer de absorção de pico
- ✅ Fonte de verdade temporária (7 dias)
- ✅ Ponto de replay
- ✅ Contrato entre sistemas

## 📊 Arquitetura

```
┌──────────────────────────────────────────────────────────────────┐
│                         Event Gateway (Go)                        │
│            HTTP → Validação → Kafka Producer                      │
└────────────────────────┬─────────────────────────────────────────┘
                         │
                         ▼
┌──────────────────────────────────────────────────────────────────┐
│                      Apache Kafka Cluster                         │
│                                                                   │
│  ┌────────────┐  ┌────────────┐  ┌────────────┐                │
│  │  Broker 0  │  │  Broker 1  │  │  Broker 2  │                │
│  │  (kafka-0) │  │  (kafka-1) │  │  (kafka-2) │                │
│  └────────────┘  └────────────┘  └────────────┘                │
│                                                                   │
│  Topics:                                                          │
│  • saude.auditoria.login       (3 partitions, replication: 2)   │
│  • saude.auditoria.acesso      (3 partitions, replication: 2)   │
│  • saude.auditoria.alteracao   (3 partitions, replication: 2)   │
│  • saude.auditoria.operacao    (3 partitions, replication: 2)   │
│  • *.dlq (Dead Letter Queue)                                     │
│                                                                   │
└────────────────┬───────────────────┬────────────────────────────┘
                 │                   │
        ┌────────┴────────┐  ┌──────┴────────┐
        │                 │  │               │
        ▼                 ▼  ▼               ▼
┌─────────────┐  ┌──────────────┐  ┌──────────────┐
│ ClickHouse  │  │   Redis      │  │  S3 Glacier  │
│ (OLAP)      │  │ (Real-time)  │  │  (Archive)   │
│ Consumer    │  │  Consumer    │  │  Consumer    │
└─────────────┘  └──────────────┘  └──────────────┘
```

## 🚀 Quick Start

### 1. Deploy do Cluster

```bash
# Deploy completo (Zookeeper + Kafka + Schema Registry + Monitoring)
kubectl apply -f base/namespace.yaml
kubectl apply -f base/zookeeper.yaml
kubectl wait --for=condition=ready pod -l app=zookeeper -n kafka --timeout=300s

kubectl apply -f base/kafka-broker.yaml
kubectl wait --for=condition=ready pod -l app=kafka -n kafka --timeout=300s

kubectl apply -f base/schema-registry.yaml
kubectl apply -f monitoring/kafka-ui.yaml
kubectl apply -f monitoring/kafka-exporter.yaml
```

### 2. Criar Topics

```bash
# Executar Job que cria todos os topics
kubectl apply -f base/kafka-topics.yaml

# Verificar criação
kubectl logs -n kafka -l job-name=kafka-create-topics
```

### 3. Verificar Saúde

```bash
# Usar helper script
./scripts/kafka-helper.sh health

# Output esperado:
# zookeeper-0: imok
# zookeeper-1: imok
# zookeeper-2: imok
# kafka-0: OK
# kafka-1: OK
# kafka-2: OK
```

### 4. Acessar Kafka UI

```bash
# Port-forward
./scripts/kafka-helper.sh ui

# Ou via Ingress (depois de configurar DNS)
# https://kafka-ui.saude.pi.gov.br
```

## 📋 Topics Criados

| Topic | Partitions | Replication | Retention | Uso |
|-------|------------|-------------|-----------|-----|
| `saude.auditoria.login` | 3 | 2 | 7 dias | Eventos de login/logout |
| `saude.auditoria.acesso` | 3 | 2 | 7 dias | Acessos a recursos |
| `saude.auditoria.alteracao` | 3 | 2 | 7 dias | Alterações de dados |
| `saude.auditoria.operacao` | 3 | 2 | 7 dias | Operações gerais |
| `saude.security.alerts` | 3 | 2 | 7 dias | Alertas de segurança |
| `*.dlq` | 3 | 2 | 30 dias | Dead Letter Queue |

## 🔑 Conceitos Fundamentais

### Desacoplamento Temporal

```
Produtor → Kafka → Consumer

Rails pode cair    → auditoria NÃO se perde
ClickHouse cai     → eventos ficam retidos
Consumer com bug   → reprocessar do offset
Novo consumer      → ler histórico sem mudar producer
```

### Partitions e Paralelismo

```yaml
Topic: saude.auditoria.login
Partitions: 3

# Significa:
# - Até 3 consumers processando em paralelo (por consumer group)
# - Key = event_id garante ordem por evento
# - Key = operador_id garantiria ordem por operador
```

### Consumer Groups

```yaml
# Consumer Group 1: auditoria-consumers
# - Lê TODAS as mensagens
# - Persiste em ClickHouse
# - Offset próprio

# Consumer Group 2: security-alerts
# - Lê TODAS as mensagens
# - Detecta anomalias
# - Offset próprio (independente do grupo 1)
```

**Isso é fan-out nativo!**

### Replay (Superpoder do Kafka)

```bash
# Situação: Bug no consumer, dados incorretos no ClickHouse

# Solução:
1. Parar consumer
2. Limpar ClickHouse
3. Resetar offset para 7 dias atrás
4. Religar consumer
5. Reprocessar automaticamente

# Comando:
./scripts/kafka-helper.sh consumer-reset \
  auditoria-consumers \
  saude.auditoria.login \
  --to-earliest
```

## 🛠️ Operações Comuns

### Listar Topics

```bash
./scripts/kafka-helper.sh topics-list
```

### Criar Novo Topic

```bash
./scripts/kafka-helper.sh topics-create \
  saude.auditoria.novo-evento \
  3 \  # partitions
  2    # replication
```

### Produzir Mensagem (Teste)

```bash
./scripts/kafka-helper.sh produce saude.auditoria.login
# Digite a mensagem JSON e Ctrl+D

# Exemplo:
{"event_id": "test-1", "operador_id": "123", "timestamp": "2026-01-05T10:00:00Z"}
```

### Consumir Mensagens

```bash
# Desde o início
./scripts/kafka-helper.sh consume saude.auditoria.login --from-beginning

# Apenas novas (tail)
./scripts/kafka-helper.sh consume saude.auditoria.login
```

### Monitorar Consumer Groups

```bash
# Listar groups
./scripts/kafka-helper.sh consumer-groups

# Detalhar lag
./scripts/kafka-helper.sh consumer-describe auditoria-consumers
```

### Ver Logs

```bash
# Broker 0
./scripts/kafka-helper.sh logs-broker 0

# Zookeeper 1
./scripts/kafka-helper.sh logs-zookeeper 1
```

## 🔧 Configurações Importantes

### Garantias de Entrega

```yaml
# Producer (Event Gateway)
acks: all                    # Aguarda replicação
retries: 3                   # Retry automático
idempotence: true           # Evita duplicatas

# Topic
min.insync.replicas: 1      # Mínimo de réplicas in-sync
replication.factor: 2        # 2 cópias de cada partition
```

Resultado: **At-least-once delivery** (correto para auditoria)

### Retention (7 dias)

```yaml
log.retention.hours: 168     # 7 dias
log.retention.bytes: 1GB     # 1GB por partition
```

Por que 7 dias?
- ✅ Replay de bugs recentes
- ✅ Reconstrução de ClickHouse
- ✅ Investigação de incidentes
- ✅ Compliance temporário
- ⚠️ S3 = histórico permanente

### Compression

```yaml
compression.type: snappy
```

Snappy é ideal para:
- ✅ Baixa latência
- ✅ Boa compressão (~50%)
- ✅ CPU eficiente

## 📊 Monitoramento

### Kafka UI

Interface web completa:

```bash
# Local
./scripts/kafka-helper.sh ui

# Produção
https://kafka-ui.saude.pi.gov.br
```

Funcionalidades:
- 📊 Visualizar topics e mensagens
- 🔍 Buscar por key/offset
- 📈 Métricas de throughput
- 👥 Monitorar consumer groups
- ⚙️ Gerenciar configurações

### Métricas Prometheus

```bash
# Endpoint
kubectl port-forward -n kafka svc/kafka-exporter 9308:9308

# Métricas
curl http://localhost:9308/metrics | grep kafka_
```

Principais métricas:
- `kafka_topic_partition_current_offset`
- `kafka_consumergroup_lag`
- `kafka_broker_info`
- `kafka_topic_partitions`

### Health Check

```bash
./scripts/kafka-helper.sh health

# Ou manual
kubectl exec -n kafka kafka-0 -- \
  kafka-broker-api-versions --bootstrap-server localhost:9092
```

## 🔐 Segurança

### Autenticação (Atual: PLAINTEXT)

```yaml
# Produção deve usar:
KAFKA_LISTENER_SECURITY_PROTOCOL_MAP: "INTERNAL:SASL_PLAINTEXT"
```

### Network Policies

```yaml
# Apenas namespace autorizado pode acessar
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: kafka-network-policy
  namespace: kafka
spec:
  podSelector:
    matchLabels:
      app: kafka
  ingress:
    - from:
      - namespaceSelector:
          matchLabels:
            name: saude-auditoria
```

### Schema Registry

Contratos de dados:

```bash
# Registrar schema
curl -X POST http://schema-registry:8081/subjects/saude.auditoria.login-value/versions \
  -H "Content-Type: application/vnd.schemaregistry.v1+json" \
  -d @login-schema.avro

# Schema evolution: BACKWARD
# - Novos schemas podem ler dados antigos
# - Adicionar campos com default: OK
# - Remover campos obrigatórios: QUEBRA
```

## 🚨 Troubleshooting

### Broker não inicia

```bash
# Ver logs
kubectl logs -n kafka kafka-0

# Erros comuns:
# - Zookeeper não está pronto
# - PVC não montou
# - Porta 9092 em uso
```

### Consumer com LAG alto

```bash
# Ver lag
./scripts/kafka-helper.sh consumer-describe auditoria-consumers

# Soluções:
# 1. Escalar replicas do consumer
# 2. Aumentar max.poll.records
# 3. Otimizar processamento
# 4. Adicionar partitions (CUIDADO: operação delicada)
```

### Mensagens não chegam

```bash
# 1. Verificar se producer está enviando
./scripts/kafka-helper.sh consume saude.auditoria.login --from-beginning

# 2. Verificar offset do consumer
./scripts/kafka-helper.sh consumer-describe auditoria-consumers

# 3. Ver Dead Letter Queue
./scripts/kafka-helper.sh consume saude.auditoria.login.dlq --from-beginning
```

### Zookeeper instável

```bash
# Ver logs de todos os nodes
for i in 0 1 2; do
  echo "=== zookeeper-$i ==="
  kubectl logs -n kafka zookeeper-$i --tail=50
done

# Verificar quorum
kubectl exec -n kafka zookeeper-0 -- \
  bash -c 'echo stat | nc localhost 2181'
```

## 📈 Escalabilidade

### Adicionar Broker

```bash
# Editar StatefulSet
kubectl edit statefulset kafka -n kafka

# Aumentar replicas
spec:
  replicas: 4  # era 3
```

### Adicionar Partitions

```bash
# CUIDADO: Não pode diminuir!
kubectl exec -n kafka kafka-0 -- \
  kafka-topics --alter \
  --bootstrap-server localhost:9092 \
  --topic saude.auditoria.login \
  --partitions 6  # era 3
```

### Rebalancear Partitions

```bash
# Gerar plano de reassignment
kafka-reassign-partitions --generate \
  --bootstrap-server localhost:9092 \
  --broker-list "0,1,2,3" \
  --topics-to-move-json-file topics.json

# Executar reassignment
kafka-reassign-partitions --execute \
  --bootstrap-server localhost:9092 \
  --reassignment-json-file reassignment.json
```

## 📚 Documentação Adicional

- **Arquitetura Detalhada**: [ARQUITETURA.md](./ARQUITETURA.md)
- **Schema Evolution**: [docs/schema-evolution.md](./docs/schema-evolution.md)
- **Disaster Recovery**: [docs/disaster-recovery.md](./docs/disaster-recovery.md)
- **Performance Tuning**: [docs/performance.md](./docs/performance.md)

## 🔗 Recursos

- **Kafka UI**: https://kafka-ui.saude.pi.gov.br
- **Prometheus Metrics**: http://kafka-exporter:9308/metrics
- **Schema Registry**: http://schema-registry:8081
- **Documentação Oficial**: https://kafka.apache.org/documentation/
- **Confluent Docs**: https://docs.confluent.io/

## 📞 Suporte

- **Helper Script**: `./scripts/kafka-helper.sh help`
- **Logs**: `kubectl logs -n kafka -l app=kafka -f`
- **Status**: `./scripts/kafka-helper.sh status`

## ⚡ Comandos Rápidos

```bash
# Status geral
./scripts/kafka-helper.sh status

# Saúde do cluster
./scripts/kafka-helper.sh health

# Listar topics
./scripts/kafka-helper.sh topics-list

# Ver mensagens
./scripts/kafka-helper.sh consume saude.auditoria.login --from-beginning

# Monitorar lag
./scripts/kafka-helper.sh consumer-describe auditoria-consumers

# Abrir UI
./scripts/kafka-helper.sh ui

# Logs do broker 0
./scripts/kafka-helper.sh logs-broker 0
```

---

**Lembre-se**: Kafka não é sobre velocidade. Kafka é sobre **desacoplamento no tempo**. 🚀
