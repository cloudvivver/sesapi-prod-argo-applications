# saude-bi — namespace BI (Gateway + Kafka + Consumer + ClickHouse)

Namespace central para a pipeline de eventos de etapas do atendimento:

**Rails (vários ambientes) → Gateway → Kafka → Consumer → ClickHouse (bi_etapas)**

A visualização é feita pelo legado Rails consultando diretamente o ClickHouse.

## Manifestos

| Arquivo | Descrição |
|---------|-----------|
| `namespace.yaml` | Namespace `saude-bi` |
| `limitrange.yaml` | Limites padrão de recursos |
| `env-configmap.yaml` | Kafka brokers, topic, ClickHouse host/port/db |
| `clickhouse.yaml` | ClickHouse StatefulSet + Service (porta 8123/9000, PVC 10Gi) |
| `gateway-deployment.yaml` | Gateway HTTP que recebe eventos e publica no Kafka |
| `gateway-secret.example.yaml` | Exemplo de Secret para GATEWAY_SECRET (HMAC) |
| `gateway-service.yaml` | Service do gateway |
| `kafka-broker.yaml` | Kafka + Zookeeper |
| `zookeeper.yaml` | Zookeeper |
| `etapas-consumer-deployment.yaml` | Consumer Kafka → ClickHouse |

## Ordem de aplicação

```bash
kubectl apply -f namespace.yaml
kubectl apply -f limitrange.yaml
kubectl apply -f env-configmap.yaml
kubectl apply -f zookeeper.yaml
kubectl apply -f kafka-broker.yaml
kubectl apply -f clickhouse.yaml

# Gateway: criar Secret com o mesmo valor de AUDITORIA_GATEWAY_SECRET dos namespaces Rails
kubectl apply -f gateway-secret.example.yaml  # copiar, preencher e aplicar
kubectl apply -f gateway-deployment.yaml
kubectl apply -f gateway-service.yaml

kubectl apply -f etapas-consumer-deployment.yaml
```

## Acesso local ao ClickHouse (desenvolvimento)

```bash
kubectl port-forward svc/clickhouse 8123:8123 -n saude-bi
curl "http://localhost:8123/?query=SHOW+TABLES+FROM+bi_etapas"
```

## Documentação

Ver em `saude-publica-legado/docs/arquitetura-eventos-relatorio-etapas.md`.
