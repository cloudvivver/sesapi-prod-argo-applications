#!/bin/bash

# Script para configurar conectores Kafka Connect

KAFKA_CONNECT_URL="http://localhost:8083"
NAMESPACE="cuidar-isac-hml"
POD_NAME=$(kubectl get pods -n $NAMESPACE -l app=kafka-connect-debezium-isac -o jsonpath='{.items[0].metadata.name}')

echo "Configurando conectores no pod: $POD_NAME"

# Configuração do conector Debezium PostgreSQL
POSTGRES_CONFIG=$(cat <<'EOF'
{
  "name": "postgres-cdc-connector",
  "config": {
    "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
    "tasks.max": "1",
    "database.hostname": "dev-db-cuidar-new2.postgres.database.azure.com",
    "database.port": "6432",
    "database.user": "postgres",
    "database.password": "nt1L2e0AFiRn6FREfYf9hXUWcO3gsOTs",
    "database.dbname": "saude_homolog_tenant_isac_db",
    "database.server.name": "isac-postgres",
    "table.include.list": "public.*",
    "plugin.name": "pgoutput",
    "publication.autocreate.mode": "filtered", 
    "slot.name": "debezium_isac_slot",
    "topic.prefix": "isac-cdc",
    "schema.history.internal.kafka.bootstrap.servers": "kafka:9092",
    "schema.history.internal.kafka.topic": "isac-schema-history",
    "key.converter": "org.apache.kafka.connect.json.JsonConverter",
    "value.converter": "org.apache.kafka.connect.json.JsonConverter",
    "key.converter.schemas.enable": "false",
    "value.converter.schemas.enable": "false"
  }
}
EOF
)

echo "Criando conector PostgreSQL CDC..."
kubectl exec -n $NAMESPACE $POD_NAME -- curl -X POST \
  -H "Content-Type: application/json" \
  -d "$POSTGRES_CONFIG" \
  $KAFKA_CONNECT_URL/connectors

echo -e "\nListando conectores existentes:"
kubectl exec -n $NAMESPACE $POD_NAME -- curl -s $KAFKA_CONNECT_URL/connectors

echo -e "\nVerificando status do conector:"
kubectl exec -n $NAMESPACE $POD_NAME -- curl -s $KAFKA_CONNECT_URL/connectors/postgres-cdc-connector/status