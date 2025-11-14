#!/bin/bash

KAFKA_CONNECT_URL="http://localhost:8083"
NAMESPACE="cuidar-isac-hml"
POD_NAME=$(kubectl get pods -n $NAMESPACE -l app=kafka-connect-debezium-isac -o jsonpath='{.items[0].metadata.name}')

# Testar conectividade com PostgreSQL primeiro
echo "Testando conectividade com PostgreSQL..."

SIMPLE_CONFIG=$(cat <<'EOF'
{
  "name": "postgres-test-connector",
  "config": {
    "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
    "tasks.max": "1",
    "database.hostname": "dev-db-cuidar-new2.postgres.database.azure.com",
    "database.port": "6432", 
    "database.user": "postgres",
    "database.password": "nt1L2e0AFiRn6FREfYf9hXUWcO3gsOTs",
    "database.dbname": "saude_homolog_tenant_isac_db",
    "database.server.name": "isac-postgres",
    "plugin.name": "pgoutput",
    "slot.name": "debezium_test_slot",
    "topic.prefix": "isac-test",
    "schema.history.internal.kafka.bootstrap.servers": "kafka:9092",
    "schema.history.internal.kafka.topic": "isac-test-schema-history"
  }
}
EOF
)

echo "Testando configuração básica..."
kubectl exec -n $NAMESPACE $POD_NAME -- curl -X POST \
  -H "Content-Type: application/json" \
  -d "$SIMPLE_CONFIG" \
  $KAFKA_CONNECT_URL/connectors