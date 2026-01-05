#!/bin/bash
#
# Kafka Helper Script - Facilita operações com Kafka
#

set -e

NAMESPACE="kafka"

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info() {
    echo -e "${BLUE}ℹ ${1}${NC}"
}

print_success() {
    echo -e "${GREEN}✅ ${1}${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ ${1}${NC}"
}

print_error() {
    echo -e "${RED}❌ ${1}${NC}"
}

# Obter pod do Kafka
get_kafka_pod() {
    kubectl get pods -n $NAMESPACE -l app=kafka -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# COMANDOS

cmd_status() {
    print_info "Status do Kafka Cluster:"
    echo ""
    echo "=== PODS ==="
    kubectl get pods -n $NAMESPACE
    echo ""
    echo "=== SERVICES ==="
    kubectl get svc -n $NAMESPACE
    echo ""
    echo "=== PVCs ==="
    kubectl get pvc -n $NAMESPACE
}

cmd_topics_list() {
    print_info "Listando todos os topics:"
    POD=$(get_kafka_pod)
    kubectl exec -n $NAMESPACE $POD -- \
        kafka-topics --list \
        --bootstrap-server localhost:9092
}

cmd_topics_describe() {
    if [ -z "$2" ]; then
        print_error "Uso: $0 topic-describe <nome-do-topic>"
        exit 1
    fi
    TOPIC=$2
    print_info "Descrevendo topic: $TOPIC"
    POD=$(get_kafka_pod)
    kubectl exec -n $NAMESPACE $POD -- \
        kafka-topics --describe \
        --bootstrap-server localhost:9092 \
        --topic "$TOPIC"
}

cmd_topics_create() {
    if [ -z "$2" ]; then
        print_error "Uso: $0 topic-create <nome-do-topic> [partitions] [replication]"
        exit 1
    fi
    TOPIC=$2
    PARTITIONS=${3:-3}
    REPLICATION=${4:-2}

    print_info "Criando topic: $TOPIC"
    print_info "Partitions: $PARTITIONS, Replication: $REPLICATION"

    POD=$(get_kafka_pod)
    kubectl exec -n $NAMESPACE $POD -- \
        kafka-topics --create \
        --bootstrap-server localhost:9092 \
        --topic "$TOPIC" \
        --partitions "$PARTITIONS" \
        --replication-factor "$REPLICATION" \
        --config retention.ms=604800000

    print_success "Topic criado!"
}

cmd_topics_delete() {
    if [ -z "$2" ]; then
        print_error "Uso: $0 topic-delete <nome-do-topic>"
        exit 1
    fi
    TOPIC=$2

    print_warning "ATENÇÃO: Isso deletará o topic $TOPIC permanentemente!"
    read -p "Tem certeza? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Operação cancelada"
        exit 0
    fi

    POD=$(get_kafka_pod)
    kubectl exec -n $NAMESPACE $POD -- \
        kafka-topics --delete \
        --bootstrap-server localhost:9092 \
        --topic "$TOPIC"

    print_success "Topic deletado!"
}

cmd_consumer_groups() {
    print_info "Listando Consumer Groups:"
    POD=$(get_kafka_pod)
    kubectl exec -n $NAMESPACE $POD -- \
        kafka-consumer-groups --list \
        --bootstrap-server localhost:9092
}

cmd_consumer_describe() {
    if [ -z "$2" ]; then
        print_error "Uso: $0 consumer-describe <group-id>"
        exit 1
    fi
    GROUP=$2
    print_info "Descrevendo Consumer Group: $GROUP"
    POD=$(get_kafka_pod)
    kubectl exec -n $NAMESPACE $POD -- \
        kafka-consumer-groups --describe \
        --bootstrap-server localhost:9092 \
        --group "$GROUP"
}

cmd_consumer_reset() {
    if [ -z "$2" ] || [ -z "$3" ]; then
        print_error "Uso: $0 consumer-reset <group-id> <topic> [--to-earliest|--to-latest|--to-offset N]"
        exit 1
    fi
    GROUP=$2
    TOPIC=$3
    RESET_OPTION=${4:---to-latest}

    print_warning "ATENÇÃO: Isso resetará o offset do consumer group $GROUP no topic $TOPIC"
    read -p "Tem certeza? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Operação cancelada"
        exit 0
    fi

    POD=$(get_kafka_pod)
    kubectl exec -n $NAMESPACE $POD -- \
        kafka-consumer-groups --reset-offsets \
        --bootstrap-server localhost:9092 \
        --group "$GROUP" \
        --topic "$TOPIC" \
        "$RESET_OPTION" \
        --execute

    print_success "Offset resetado!"
}

cmd_produce() {
    if [ -z "$2" ]; then
        print_error "Uso: $0 produce <topic>"
        print_info "Digite as mensagens (uma por linha, Ctrl+D para finalizar)"
        exit 1
    fi
    TOPIC=$2

    print_info "Produzindo mensagens para topic: $TOPIC"
    print_info "Digite as mensagens (Ctrl+D para finalizar):"

    POD=$(get_kafka_pod)
    kubectl exec -i -n $NAMESPACE $POD -- \
        kafka-console-producer \
        --bootstrap-server localhost:9092 \
        --topic "$TOPIC"
}

cmd_consume() {
    if [ -z "$2" ]; then
        print_error "Uso: $0 consume <topic> [--from-beginning]"
        exit 1
    fi
    TOPIC=$2
    FROM_BEGINNING=${3:-}

    print_info "Consumindo mensagens do topic: $TOPIC (Ctrl+C para sair)"
    POD=$(get_kafka_pod)
    kubectl exec -n $NAMESPACE $POD -- \
        kafka-console-consumer \
        --bootstrap-server localhost:9092 \
        --topic "$TOPIC" \
        $FROM_BEGINNING
}

cmd_logs_broker() {
    BROKER=${2:-0}
    print_info "Logs do Kafka Broker $BROKER (Ctrl+C para sair):"
    kubectl logs -n $NAMESPACE kafka-$BROKER -f --tail=100
}

cmd_logs_zookeeper() {
    ZK=${2:-0}
    print_info "Logs do Zookeeper $ZK (Ctrl+C para sair):"
    kubectl logs -n $NAMESPACE zookeeper-$ZK -f --tail=100
}

cmd_shell_broker() {
    BROKER=${2:-0}
    print_info "Abrindo shell no Kafka Broker $BROKER..."
    kubectl exec -it -n $NAMESPACE kafka-$BROKER -- /bin/bash
}

cmd_metrics() {
    print_info "Verificando métricas do Kafka Exporter:"
    kubectl port-forward -n $NAMESPACE svc/kafka-exporter 9308:9308 &
    PF_PID=$!
    sleep 2
    curl -s http://localhost:9308/metrics | grep kafka_
    kill $PF_PID
}

cmd_ui() {
    print_info "Abrindo Kafka UI..."
    print_success "Acesse: http://localhost:8080"
    kubectl port-forward -n $NAMESPACE svc/kafka-ui 8080:8080
}

cmd_health() {
    print_info "Verificando saúde do cluster:"
    echo ""
    echo "=== ZOOKEEPER ==="
    for i in 0 1 2; do
        echo -n "zookeeper-$i: "
        kubectl exec -n $NAMESPACE zookeeper-$i -- \
            bash -c 'echo ruok | nc localhost 2181' 2>/dev/null || echo "FAIL"
    done
    echo ""
    echo "=== KAFKA BROKERS ==="
    for i in 0 1 2; do
        echo -n "kafka-$i: "
        kubectl exec -n $NAMESPACE kafka-$i -- \
            kafka-broker-api-versions --bootstrap-server localhost:9092 > /dev/null 2>&1 && echo "OK" || echo "FAIL"
    done
}

cmd_help() {
    cat << EOF
${BLUE}Kafka Helper Script${NC}
Facilita operações com Kafka no Kubernetes

${GREEN}Comandos disponíveis:${NC}

  ${YELLOW}Status e Monitoramento:${NC}
    status              - Status de pods, services e PVCs
    health              - Verifica saúde de Zookeeper e Kafka
    ui                  - Abre Kafka UI (port-forward)
    metrics             - Visualiza métricas do Kafka Exporter

  ${YELLOW}Topics:${NC}
    topics-list         - Lista todos os topics
    topics-describe <topic> - Detalha um topic
    topics-create <topic> [partitions] [replication] - Cria um topic
    topics-delete <topic> - Deleta um topic

  ${YELLOW}Consumer Groups:${NC}
    consumer-groups     - Lista todos os consumer groups
    consumer-describe <group> - Detalha um consumer group
    consumer-reset <group> <topic> [option] - Reseta offset

  ${YELLOW}Produção e Consumo:${NC}
    produce <topic>     - Produz mensagens interativamente
    consume <topic> [--from-beginning] - Consome mensagens

  ${YELLOW}Logs e Debug:${NC}
    logs-broker [0|1|2] - Logs de um broker específico
    logs-zookeeper [0|1|2] - Logs do Zookeeper
    shell-broker [0|1|2] - Shell em um broker

  ${YELLOW}Ajuda:${NC}
    help                - Mostra esta mensagem

${GREEN}Exemplos:${NC}
  $0 status
  $0 topics-list
  $0 consumer-describe auditoria-consumers
  $0 consume saude.auditoria.login --from-beginning
  $0 ui

${BLUE}Kafka UI:${NC} http://kafka-ui.saude.pi.gov.br
EOF
}

# Main
case "${1:-help}" in
    status) cmd_status ;;
    health) cmd_health ;;
    topics-list) cmd_topics_list ;;
    topics-describe) cmd_topics_describe "$@" ;;
    topics-create) cmd_topics_create "$@" ;;
    topics-delete) cmd_topics_delete "$@" ;;
    consumer-groups) cmd_consumer_groups ;;
    consumer-describe) cmd_consumer_describe "$@" ;;
    consumer-reset) cmd_consumer_reset "$@" ;;
    produce) cmd_produce "$@" ;;
    consume) cmd_consume "$@" ;;
    logs-broker) cmd_logs_broker "$@" ;;
    logs-zookeeper) cmd_logs_zookeeper "$@" ;;
    shell-broker) cmd_shell_broker "$@" ;;
    metrics) cmd_metrics ;;
    ui) cmd_ui ;;
    help|--help|-h) cmd_help ;;
    *)
        print_error "Comando desconhecido: $1"
        echo ""
        cmd_help
        exit 1
        ;;
esac
