#!/bin/bash

# Comprehensive Elasticsearch and Kibana Export Script
# Prerequisites: jq installed, $OAPI_KEY (on-prem) and $CAPI_KEY (cloud) set in your environment

# Define base URLs


CLOUD_ES_URL="hhttps://kibhana_url_here.com"
CLOUD_KIBANA="https://kibhana_url_here.com"


LOCAL_ES_URL="https://kibhana_url_here.com"
LOCAL_KIBANA="https://kibhana_url_here.com"
API_KEY="REDACTED_API_KEY"



EXPORT_DIR="elastic_export_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$EXPORT_DIR"
cd "$EXPORT_DIR"

# Function for Elasticsearch API requests
es_request() {
    local env=$1
    local method=$2
    local endpoint=$3
    local data=$4

    if [ "$#" -lt 3 ]; then
        echo "Usage: es_request <env> <HTTP_METHOD> <API_ENDPOINT> [<DATA>]"
        return 1
    fi

    local base_url=""
    local api_key=""

    if [ "$env" == "local" ]; then
        base_url="$LOCAL_ES_URL"
        api_key="$OAPI_KEY"
    elif [ "$env" == "cloud" ]; then
        base_url="$CLOUD_ES_URL"
        api_key="$CAPI_KEY"
    else
        echo "Invalid environment: $env. Use 'local' or 'cloud'"
        return 1
    fi

    if [ "$method" == "GET" ]; then
        curl -s -X GET -H "Authorization: ApiKey $api_key" "$base_url/$endpoint"
    elif [ "$method" == "PUT" ]; then
        curl -s -X PUT -H "Authorization: ApiKey $api_key" -H "Content-Type: application/json" -d "$data" "$base_url/$endpoint"
    else
        echo "Unsupported HTTP method: $method"
        return 1
    fi
}

# Function for Kibana API requests
kibana_request() {
    local env=$1
    local method=$2
    local endpoint=$3
    local data=$4
    
    local base_url=""
    local api_key=""

    if [ "$env" == "local" ]; then
        base_url="$LOCAL_KIBANA"
        api_key="$OAPI_KEY"
    elif [ "$env" == "cloud" ]; then
        base_url="$CLOUD_KIBANA"
        api_key="$CAPI_KEY"
    else
        echo "Invalid environment: $env. Use 'local' or 'cloud'"
        return 1
    fi

    if [ "$method" == "GET" ]; then
        curl -s -X GET "$base_url/$endpoint" \
          -H "kbn-xsrf: true" \
          -H "Authorization: ApiKey $api_key" \
          -H "Content-Type: application/json"
    elif [ "$method" == "POST" ]; then
        if [ -n "$data" ]; then
            curl -s -X POST "$base_url/$endpoint" \
              -H "kbn-xsrf: true" \
              -H "Authorization: ApiKey $api_key" \
              -H "Content-Type: application/json" \
              -d "$data"
        else
            curl -s -X POST "$base_url/$endpoint" \
              -H "kbn-xsrf: true" \
              -H "Authorization: ApiKey $api_key" \
              -H "Content-Type: application/json"
        fi
    else
        echo "Unsupported HTTP method: $method"
        return 1
    fi
}

# Function to export Kibana saved objects for all spaces
export_kibana_saved_objects() {
    local env=$1
    local base_url=""
    local api_key=""

    if [ "$env" == "local" ]; then
        base_url="$LOCAL_KIBANA"
        api_key="$OAPI_KEY"
    elif [ "$env" == "cloud" ]; then
        base_url="$CLOUD_KIBANA"
        api_key="$CAPI_KEY"
    else
        echo "Invalid environment: $env. Use 'local' or 'cloud'"
        return 1
    fi

    # Get all spaces
    local spaces=$(curl -s -X GET "${base_url}/api/spaces/space" \
      -H "kbn-xsrf: true" \
      -H "Authorization: ApiKey ${api_key}" \
      -H "Content-Type: application/json")

    # Extract space IDs
    local space_ids=$(echo "$spaces" | jq -r '.[].id')

    # Create directory for saved objects
    mkdir -p "${env}_saved_objects"

    # Loop through each space and export all saved objects
    for space in $space_ids; do
        echo "Exporting saved objects from ${env} space: $space"
        curl -s -X POST "${base_url}/s/${space}/api/saved_objects/_export" \
          -H "kbn-xsrf: true" \
          -H "Authorization: ApiKey ${api_key}" \
          -H "Content-Type: application/json" \
          -d '{"type": ["*"], "excludeExportDetails": true, "includeReferencesDeep": true}' \
          --output "${env}_saved_objects/${env}_kibana_space_${space}_export.ndjson"
    done
}

# Main export function
export_resources() {
    echo "Exporting Elasticsearch objects..."

    # Create directories for better organization
    mkdir -p es_resources/local es_resources/cloud kibana/local kibana/cloud

    # Cluster settings
    es_request "cloud" "GET" "_cluster/settings?include_defaults=false" | jq '.persistent' > es_resources/cloud/cluster_settings.json
    es_request "local" "GET" "_cluster/settings?include_defaults=false" | jq '.persistent' > es_resources/local/cluster_settings.json

    # ILM policies
    es_request "cloud" "GET" "_ilm/policy" | jq '.' > es_resources/cloud/ilm_policy.json
    es_request "local" "GET" "_ilm/policy" | jq '.' > es_resources/local/ilm_policy.json

    # Index templates
    es_request "cloud" "GET" "_index_template" | jq '.' > es_resources/cloud/index_templates.json
    es_request "local" "GET" "_index_template" | jq '.' > es_resources/local/index_templates.json

    # Security roles
    es_request "cloud" "GET" "_security/role" | jq '.' > es_resources/cloud/security_roles.json
    es_request "local" "GET" "_security/role" | jq '.' > es_resources/local/security_roles.json

    # Snapshot repositories
    es_request "cloud" "GET" "_snapshot" | jq '.' > es_resources/cloud/snapshot_repos.json
    es_request "local" "GET" "_snapshot" | jq '.' > es_resources/local/snapshot_repos.json

    # Logstash pipelines
    es_request "cloud" "GET" "_logstash/pipeline" | jq '.' > es_resources/cloud/logstash_pipelines.json
    es_request "local" "GET" "_logstash/pipeline" | jq '.' > es_resources/local/logstash_pipelines.json

    echo "Exporting Kibana spaces..."

    # # Kibana spaces
    kibana_request "cloud" "GET" "api/spaces/space" | jq '.' > kibana/cloud/kibana_spaces.json
    kibana_request "local" "GET" "api/spaces/space" | jq '.' > kibana/local/kibana_spaces.json

    echo "Exporting Kibana saved objects for all spaces..."
    
    # Export saved objects for all spaces
    export_kibana_saved_objects "cloud"
    export_kibana_saved_objects "local"

    echo "All exports complete. Files saved to $(pwd)"
}

# Show help message
show_help() {
    echo "Usage:"
    echo "  $0                                     - Run full export process"
    echo "  $0 es <env> <method> <endpoint> [data] - Make direct Elasticsearch API call"
    echo "  $0 kb <env> <method> <endpoint> [data] - Make direct Kibana API call"
    echo "  $0 saved-objects <env>                - Export saved objects for all spaces"
    echo "  $0 help                               - Show this help message"
    echo ""
    echo "Parameters:"
    echo "  <env>     - Environment: 'local' or 'cloud'"
    echo "  <method>  - HTTP method: 'GET', 'PUT', 'POST', etc."
    echo "  <endpoint> - API endpoint path"
    echo "  [data]    - Optional JSON data for POST/PUT requests"
    echo ""
    echo "Examples:"
    echo "  $0                                     - Run full export"
    echo "  $0 es local GET _cluster/health        - Get local cluster health"
    echo "  $0 kb cloud GET api/spaces/space       - Get cloud Kibana spaces"
    echo "  $0 saved-objects local                - Export all saved objects from local"
}

# Check for command-line arguments
if [ "$#" -ge 1 ]; then
    case "$1" in
        "es")
            if [ "$#" -lt 4 ]; then
                echo "Error: Insufficient arguments for ES API call"
                show_help
                exit 1
            fi
            env=$2
            method=$3
            endpoint=$4
            data=$5
            es_request "$env" "$method" "$endpoint" "$data"
            ;;
        "kb")
            if [ "$#" -lt 4 ]; then
                echo "Error: Insufficient arguments for Kibana API call"
                show_help
                exit 1
            fi
            env=$2
            method=$3
            endpoint=$4
            data=$5
            kibana_request "$env" "$method" "$endpoint" "$data"
            ;;
        "saved-objects")
            if [ "$#" -lt 2 ]; then
                echo "Error: Environment not specified for saved objects export"
