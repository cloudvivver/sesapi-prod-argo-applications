#!/bin/bash

# Script para configurar JDBC Source Connector para PostgreSQL

KAFKA_CONNECT_URL="http://localhost:8083"
NAMESPACE="cuidar-isac-hml"
POD_NAME=$(kubectl get pods -n $NAMESPACE -l app=kafka-connect-debezium-isac -o jsonpath='{.items[0].metadata.name}')

echo "Configurando JDBC Source Connector no pod: $POD_NAME"

# Configuração do conector JDBC Source
JDBC_CONFIG=$(cat <<'EOF'
{
  "name": "jdbc-postgres-source",
  "config": {
    "connector.class": "io.confluent.connect.jdbc.JdbcSourceConnector",
    "tasks.max": "1",
    "connection.url": "jdbc:postgresql://dev-db-cuidar-new2.postgres.database.azure.com:6432/saude_homolog_tenant_isac_db?sslmode=require",
    "connection.user": "postgres",
    "connection.password": "nt1L2e0AFiRn6FREfYf9hXUWcO3gsOTs",
    "mode": "incrementing",
    "incrementing.column.name": "id",
    "topic.prefix": "isac-jdbc-",
    "table.whitelist": "public.users,public.organizations",
    "poll.interval.ms": 5000,
    "key.converter": "org.apache.kafka.connect.json.JsonConverter",
    "value.converter": "org.apache.kafka.connect.json.JsonConverter",
    "key.converter.schemas.enable": "false",
    "value.converter.schemas.enable": "false"
  }
}
EOF
)

echo "Criando JDBC Source Connector..."
kubectl exec -n $NAMESPACE $POD_NAME -- curl -X POST \
  -H "Content-Type: application/json" \
  -d "$JDBC_CONFIG" \
  $KAFKA_CONNECT_URL/connectors

echo -e "\nListando conectores existentes:"
kubectl exec -n $NAMESPACE $POD_NAME -- curl -s $KAFKA_CONNECT_URL/connectors

echo -e "\nVerificando status do conector:"
kubectl exec -n $NAMESPACE $POD_NAME -- curl -s $KAFKA_CONNECT_URL/connectors/jdbc-postgres-source/status