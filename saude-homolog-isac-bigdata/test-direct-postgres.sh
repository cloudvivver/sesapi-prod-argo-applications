#!/bin/bash

# Testar conexão direta com PostgreSQL porta 5432

KAFKA_CONNECT_URL="http://localhost:8083"
NAMESPACE="cuidar-isac-hml"
POD_NAME=$(kubectl get pods -n $NAMESPACE -l app=kafka-connect-debezium-isac -o jsonpath='{.items[0].metadata.name}')

echo "Testando Debezium na porta 5432 (direto PostgreSQL) no pod: $POD_NAME"

# Configuração do conector Debezium com porta 5432
POSTGRES_CONFIG_5432=$(cat <<'EOF'
{
  "name": "postgres-cdc-direct",
  "config": {
    "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
    "tasks.max": "1",
    "database.hostname": "dev-db-cuidar-new2.postgres.database.azure.com",
    "database.port": "5432",
    "database.user": "postgres",
    "database.password": "nt1L2e0AFiRn6FREfYf9hXUWcO3gsOTs",
    "database.dbname": "saude_homolog_tenant_isac_db",
    "database.server.name": "isac-postgres",
    "plugin.name": "pgoutput",
    "slot.name": "debezium_direct_slot",
    "topic.prefix": "isac-direct",
    "schema.history.internal.kafka.bootstrap.servers": "kafka:9092",
    "schema.history.internal.kafka.topic": "isac-direct-schema-history",
    "database.sslmode": "require",
    "snapshot.mode": "initial"
  }
}
EOF
)

echo "Testando conexão direta porta 5432..."
kubectl exec -n $NAMESPACE $POD_NAME -- curl -X POST \
  -H "Content-Type: application/json" \
  -d "$POSTGRES_CONFIG_5432" \
  $KAFKA_CONNECT_URL/connectors

echo -e "\nVerificando status:"
kubectl exec -n $NAMESPACE $POD_NAME -- curl -s $KAFKA_CONNECT_URL/connectors/postgres-cdc-direct/status