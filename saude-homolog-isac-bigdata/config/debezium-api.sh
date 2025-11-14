#!/bin/bash

# Debezium CDC REST API Management Script - ISAC
# Usage: ./debezium-api.sh [command] [options]

DEBEZIUM_HOST="localhost:30085"
CONNECTOR_CONFIG_FILE="config/debezium-postgres-cdc-connector.json"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

function print_usage() {
    echo "Usage: $0 [command] [options]"
    echo ""
    echo "Commands:"
    echo "  create                    Create the Debezium CDC connector (ISAC)"
    echo "  list                      List all connectors"
    echo "  status [connector-name]   Get connector status"
    echo "  restart [connector-name]  Restart a connector"
    echo "  delete [connector-name]   Delete a connector"
    echo "  update                    Update connector configuration"
    echo "  plugins                   List available plugins"
    echo "  topics                    List CDC topics"
    echo ""
    echo "Options:"
    echo "  -h, --host               Debezium Connect host (default: $DEBEZIUM_HOST)"
    echo "  -f, --file               Connector config file (default: $CONNECTOR_CONFIG_FILE)"
}

function check_connect() {
    echo -e "${YELLOW}Checking Debezium Connect status (ISAC)...${NC}"
    if curl -s -f "http://$DEBEZIUM_HOST" > /dev/null; then
        echo -e "${GREEN}✓ Debezium Connect (ISAC) is running${NC}"
        return 0
    else
        echo -e "${RED}✗ Debezium Connect (ISAC) is not accessible at $DEBEZIUM_HOST${NC}"
        return 1
    fi
}

function create_connector() {
    echo -e "${YELLOW}Creating Debezium CDC PostgreSQL connector (ISAC)...${NC}"
    
    if [[ ! -f "$CONNECTOR_CONFIG_FILE" ]]; then
        echo -e "${RED}✗ Config file $CONNECTOR_CONFIG_FILE not found${NC}"
        return 1
    fi
    
    response=$(curl -s -X POST \
        -H "Content-Type: application/json" \
        --data @"$CONNECTOR_CONFIG_FILE" \
        "http://$DEBEZIUM_HOST/connectors")
    
    if echo "$response" | grep -q '"name"'; then
        echo -e "${GREEN}✓ Connector created successfully${NC}"
        echo "$response" | jq '.'
    else
        echo -e "${RED}✗ Failed to create connector${NC}"
        echo "$response" | jq '.'
        return 1
    fi
}

function list_connectors() {
    echo -e "${YELLOW}Listing all connectors (ISAC)...${NC}"
    curl -s "http://$DEBEZIUM_HOST/connectors" | jq '.'
}

function get_status() {
    local connector_name=${1:-"cdc-postgres-acessos-isac"}
    echo -e "${YELLOW}Getting status for connector: $connector_name${NC}"
    curl -s "http://$DEBEZIUM_HOST/connectors/$connector_name/status" | jq '.'
}

function restart_connector() {
    local connector_name=${1:-"cdc-postgres-acessos-isac"}
    echo -e "${YELLOW}Restarting connector: $connector_name${NC}"
    
    response=$(curl -s -X POST "http://$DEBEZIUM_HOST/connectors/$connector_name/restart")
    
    if [[ -z "$response" ]]; then
        echo -e "${GREEN}✓ Connector restart initiated${NC}"
    else
        echo -e "${RED}✗ Failed to restart connector${NC}"
        echo "$response"
    fi
}

function delete_connector() {
    local connector_name=${1:-"cdc-postgres-acessos-isac"}
    echo -e "${YELLOW}Deleting connector: $connector_name${NC}"
    
    response=$(curl -s -X DELETE "http://$DEBEZIUM_HOST/connectors/$connector_name")
    
    if [[ -z "$response" ]]; then
        echo -e "${GREEN}✓ Connector deleted successfully${NC}"
    else
        echo -e "${RED}✗ Failed to delete connector${NC}"
        echo "$response"
    fi
}

function update_connector() {
    local connector_name=${1:-"cdc-postgres-acessos-isac"}
    echo -e "${YELLOW}Updating connector configuration: $connector_name${NC}"
    
    if [[ ! -f "$CONNECTOR_CONFIG_FILE" ]]; then
        echo -e "${RED}✗ Config file $CONNECTOR_CONFIG_FILE not found${NC}"
        return 1
    fi
    
    # Extract just the config part from the JSON
    config=$(jq '.config' "$CONNECTOR_CONFIG_FILE")
    
    response=$(curl -s -X PUT \
        -H "Content-Type: application/json" \
        --data "$config" \
        "http://$DEBEZIUM_HOST/connectors/$connector_name/config")
    
    if echo "$response" | grep -q '"name"'; then
        echo -e "${GREEN}✓ Connector updated successfully${NC}"
        echo "$response" | jq '.'
    else
        echo -e "${RED}✗ Failed to update connector${NC}"
        echo "$response" | jq '.'
        return 1
    fi
}

function list_plugins() {
    echo -e "${YELLOW}Listing available plugins (ISAC)...${NC}"
    curl -s "http://$DEBEZIUM_HOST/connector-plugins" | jq '.'
}

function list_topics() {
    echo -e "${YELLOW}Expected CDC topics (ISAC):${NC}"
    echo "Schema seguranca:"
    echo "- isac.seguranca.operador"
    echo "- isac.seguranca.perfil"
    echo ""
    echo "Schema public:"
    echo "- isac.public.operadorsetor"
    echo "- isac.public.municipio"
    echo "- isac.public.unidadesaude"
    echo "- isac.public.setor"
    echo "- isac.public.profissional"
    echo "- isac.public.especialidade"
    echo "- isac.public.profissionalespec"
    echo "- isac.public.unidadeprofisespec"
    echo ""
    echo "Heartbeat:"
    echo "- __debezium-heartbeat.isac"
    echo ""
    echo -e "${YELLOW}To verify topics exist, check Kafka UI at: http://localhost:30080${NC}"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--host)
            DEBEZIUM_HOST="$2"
            shift 2
            ;;
        -f|--file)
            CONNECTOR_CONFIG_FILE="$2"
            shift 2
            ;;
        create)
            COMMAND="create"
            shift
            ;;
        list)
            COMMAND="list"
            shift
            ;;
        status)
            COMMAND="status"
            CONNECTOR_NAME="$2"
            shift 2
            ;;
        restart)
            COMMAND="restart"
            CONNECTOR_NAME="$2"
            shift 2
            ;;
        delete)
            COMMAND="delete"
            CONNECTOR_NAME="$2"
            shift 2
            ;;
        update)
            COMMAND="update"
            CONNECTOR_NAME="$2"
            shift 2
            ;;
        plugins)
            COMMAND="plugins"
            shift
            ;;
        topics)
            COMMAND="topics"
            shift
            ;;
        --help)
            print_usage
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            print_usage
            exit 1
            ;;
    esac
done

# Check if Debezium Connect is accessible
if ! check_connect; then
    exit 1
fi

# Execute the requested command
case $COMMAND in
    create)
        create_connector
        ;;
    list)
        list_connectors
        ;;
    status)
        get_status "$CONNECTOR_NAME"
        ;;
    restart)
        restart_connector "$CONNECTOR_NAME"
        ;;
    delete)
        delete_connector "$CONNECTOR_NAME"
        ;;
    update)
        update_connector "$CONNECTOR_NAME"
        ;;
    plugins)
        list_plugins
        ;;
    topics)
        list_topics
        ;;
    *)
        echo -e "${RED}No command specified${NC}"
        print_usage
        exit 1
        ;;
esac