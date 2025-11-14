#!/bin/bash

# Kafka Connect REST API Management Script
# Usage: ./kafka-connect-api.sh [command] [options]

KAFKA_CONNECT_HOST="localhost:30083"
CONNECTOR_CONFIG_FILE="config/azure-blob-sink-connector.json"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

function print_usage() {
    echo "Usage: $0 [command] [options]"
    echo ""
    echo "Commands:"
    echo "  create                    Create the Azure Blob Sink connector"
    echo "  list                      List all connectors"
    echo "  status [connector-name]   Get connector status"
    echo "  restart [connector-name]  Restart a connector"
    echo "  delete [connector-name]   Delete a connector"
    echo "  update                    Update connector configuration"
    echo "  plugins                   List available plugins"
    echo ""
    echo "Options:"
    echo "  -h, --host               Kafka Connect host (default: $KAFKA_CONNECT_HOST)"
    echo "  -f, --file               Connector config file (default: $CONNECTOR_CONFIG_FILE)"
}

function check_connect() {
    echo -e "${YELLOW}Checking Kafka Connect status...${NC}"
    if curl -s -f "http://$KAFKA_CONNECT_HOST" > /dev/null; then
        echo -e "${GREEN}✓ Kafka Connect is running${NC}"
        return 0
    else
        echo -e "${RED}✗ Kafka Connect is not accessible at $KAFKA_CONNECT_HOST${NC}"
        return 1
    fi
}

function create_connector() {
    echo -e "${YELLOW}Creating Azure Blob Sink connector...${NC}"
    
    if [[ ! -f "$CONNECTOR_CONFIG_FILE" ]]; then
        echo -e "${RED}✗ Config file $CONNECTOR_CONFIG_FILE not found${NC}"
        return 1
    fi
    
    response=$(curl -s -X POST \
        -H "Content-Type: application/json" \
        --data @"$CONNECTOR_CONFIG_FILE" \
        "http://$KAFKA_CONNECT_HOST/connectors")
    
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
    echo -e "${YELLOW}Listing all connectors...${NC}"
    curl -s "http://$KAFKA_CONNECT_HOST/connectors" | jq '.'
}

function get_status() {
    local connector_name=${1:-"azure-parquet-sink"}
    echo -e "${YELLOW}Getting status for connector: $connector_name${NC}"
    curl -s "http://$KAFKA_CONNECT_HOST/connectors/$connector_name/status" | jq '.'
}

function restart_connector() {
    local connector_name=${1:-"azure-parquet-sink"}
    echo -e "${YELLOW}Restarting connector: $connector_name${NC}"
    
    response=$(curl -s -X POST "http://$KAFKA_CONNECT_HOST/connectors/$connector_name/restart")
    
    if [[ -z "$response" ]]; then
        echo -e "${GREEN}✓ Connector restart initiated${NC}"
    else
        echo -e "${RED}✗ Failed to restart connector${NC}"
        echo "$response"
    fi
}

function delete_connector() {
    local connector_name=${1:-"azure-parquet-sink"}
    echo -e "${YELLOW}Deleting connector: $connector_name${NC}"
    
    response=$(curl -s -X DELETE "http://$KAFKA_CONNECT_HOST/connectors/$connector_name")
    
    if [[ -z "$response" ]]; then
        echo -e "${GREEN}✓ Connector deleted successfully${NC}"
    else
        echo -e "${RED}✗ Failed to delete connector${NC}"
        echo "$response"
    fi
}

function update_connector() {
    local connector_name=${1:-"azure-parquet-sink"}
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
        "http://$KAFKA_CONNECT_HOST/connectors/$connector_name/config")
    
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
    echo -e "${YELLOW}Listing available plugins...${NC}"
    curl -s "http://$KAFKA_CONNECT_HOST/connector-plugins" | jq '.'
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--host)
            KAFKA_CONNECT_HOST="$2"
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

# Check if Kafka Connect is accessible
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
    *)
        echo -e "${RED}No command specified${NC}"
        print_usage
        exit 1
        ;;
esac