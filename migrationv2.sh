#!/bin/bash

# Elasticsearch Migration Script v3
# Creates missing resources and creates prefixed copies of different resources
# Resolves issue with version field in ILM policies

# Colors for output
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# Cloud endpoints
ELASTIC_CLOUD_URL="https://REDACTED_ENDPOINT"
KIBANA_URL="https://REDACTED_ENDPOINT"

# Timestamp for prefixing resources
TIMESTAMP=$(date +"%Y%m%d%H%M")

# Find latest export directory
find_latest_export() {
    latest_dir=$(find . -maxdepth 1 -type d -name "elastic_export_*" | sort -r | head -n1)
    if [ -z "$latest_dir" ]; then
        echo -e "${RED}Error: No export directory found. Run export script first.${NC}"
        exit 1
    fi
    echo "$latest_dir"
}

# Cloud API request function
cloud_request() {
    local type=$1  # es or kb
    local method=$2
    local endpoint=$3
    local data=$4
    local output_type=${5:-json}  # json or raw

    local base_url=""
    if [ "$type" == "es" ]; then
        base_url="$CLOUD_ES_URL"
    elif [ "$type" == "kb" ]; then
        base_url="$CLOUD_KIBANA"
    else
        echo -e "${RED}Error: Invalid API type '$type'. Use 'es' or 'kb'.${NC}"
        return 1
    fi

    local response=""
    if [ "$method" == "GET" ]; then
        response=$(curl -s -X GET -H "Authorization: ApiKey $CAPI_KEY" "$base_url/$endpoint")
    elif [ "$method" == "PUT" ]; then
        response=$(curl -s -X PUT -H "Authorization: ApiKey $CAPI_KEY" -H "Content-Type: application/json" -d "$data" "$base_url/$endpoint")
    elif [ "$method" == "POST" ]; then
        response=$(curl -s -X POST -H "Authorization: ApiKey $CAPI_KEY" -H "Content-Type: application/json" -H "kbn-xsrf: true" -d "$data" "$base_url/$endpoint")
    else
        echo -e "${RED}Error: Unsupported HTTP method: $method${NC}"
        return 1
    fi

    if [ "$output_type" == "json" ]; then
        echo "$response" | jq '.'
    else
        echo "$response"
    fi
}

# Import saved objects
post_import_saved_objects() {
    local space=$1
    local file_path=$2
    
    echo -e "${BLUE}Importing saved objects to space '$space'...${NC}"
    
    response=$(curl -s -X POST "${CLOUD_KIBANA}/s/${space}/api/saved_objects/_import?overwrite=true" \
      -H "kbn-xsrf: true" \
      -H "Authorization: ApiKey ${CCAPI_KEY}" \
      --form file=@"$file_path")
    
    if echo "$response" | jq -e '.errors' > /dev/null 2>&1; then
        echo -e "${YELLOW}Import completed with errors:${NC}"
        echo "$response" | jq '.errors'
        return 1
    else
        echo -e "${GREEN}Import successful!${NC}"
        echo "$response" | jq '.success'
        return 0
    fi
}

# Generic comparison function
compare_resources() {
    local resource_type=$1
    local local_file=$2
    local cloud_endpoint=$3
    local api_type=$4
    local id_field=$5
    local skip_fields=$6
    local migration_func=$7
    
    if [ ! -f "$local_file" ]; then
        echo -e "${RED}Error: $resource_type file not found at $local_file${NC}"
        return 1
    fi
    
    echo -e "${BLUE}Analyzing $resource_type...${NC}"
    
    # Get cloud resources
    cloud_data=$(cloud_request "$api_type" "GET" "$cloud_endpoint" "" "raw")
    
    # Extract resource IDs/names
    local_ids=$(jq -r "$id_field" "$local_file")
    cloud_ids=$(echo "$cloud_data" | jq -r "$id_field")
    
    # Find missing resources
    missing_resources=()
    for id in $local_ids; do
        if ! echo "$cloud_ids" | grep -q "^$id$"; then
            missing_resources+=("$id")
        fi
    done
    
    # Find different resources
    different_resources=()
    for id in $local_ids; do
        if echo "$cloud_ids" | grep -q "^$id$"; then
            # Get resources and clean up fields to skip
            local_resource=$(jq --arg id "$id" "$skip_fields" "$local_file" | jq -S .)
            cloud_resource=$(echo "$cloud_data" | jq --arg id "$id" "$skip_fields" | jq -S .)
            
            if [ "$(echo "$local_resource" | md5sum)" != "$(echo "$cloud_resource" | md5sum)" ]; then
                different_resources+=("$id")
            fi
        fi
    done
    
    # Report findings
    if [ ${#missing_resources[@]} -eq 0 ] && [ ${#different_resources[@]} -eq 0 ]; then
        echo -e "${GREEN}All $resource_type are in sync. No migration needed.${NC}"
        return 0
    fi
    
    if [ ${#missing_resources[@]} -gt 0 ]; then
        echo -e "${YELLOW}Missing $resource_type in cloud (${#missing_resources[@]}):${NC}"
        for id in "${missing_resources[@]}"; do
            echo "  - $id"
        done
    fi
    
    if [ ${#different_resources[@]} -gt 0 ]; then
        echo -e "${YELLOW}Different $resource_type (${#different_resources[@]}):${NC}"
        for id in "${different_resources[@]}"; do
            echo "  - $id"
        done
    fi
    
    # Ask for migration confirmation
    read -p "Do you want to migrate these $resource_type to cloud? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Migration skipped.${NC}"
        return 0
    fi
    
    # Run the migration function
    $migration_func "$local_file" "$cloud_endpoint" "$api_type" "${missing_resources[@]}" "${different_resources[@]}"
    
    echo -e "${GREEN}$resource_type migration completed.${NC}"
}

# Migration function for ILM policies
migrate_ilm() {
    local local_file=$1
    local endpoint=$2
    local api_type=$3
    local missing=("${@:4}")
    local different=("${@:${#missing[@]}:4}")
    
    # # Migrate missing policies - remove version, modified_date, in_use_by, and snapshot_repository dependencies
    # for policy in "${missing[@]}"; do
    #     echo -e "${BLUE}Migrating missing ILM policy: $policy${NC}"
    #     policy_json=$(jq --arg p "$policy" '.[$p] | del(.version) | del(.modified_date) | del(.in_use_by) | del(.policy.phases.frozen.actions.searchable_snapshot.snapshot_repository)' "$local_file")
    #     cloud_request "$api_type" "PUT" "${endpoint}/$policy" "$policy_json"
    # done

    
    # for policy in "${missing[@]}"; do
    #     echo -e "${BLUE}Migrating missing ILM policy: $policy${NC}"
    #     policy_json=$(jq --arg p "$policy" '.[$p] | del(.version) | del(.modified_date) | del(.in_use_by)' "$local_file")
    #     cloud_request "$api_type" "PUT" "${endpoint}/$policy" "$policy_json"
    # done
    # Create prefixed copies of different policies
    # for policy in "${different[@]}"; do
    #     new_policy_name="migrated_${TIMESTAMP}_${policy}"
    #     echo -e "${BLUE}Creating new ILM policy as: $new_policy_name${NC}"
    #     policy_json=$(jq --arg p "$policy" '.[$p] | del(.version)' "$local_file")
    #     cloud_request "$api_type" "PUT" "${endpoint}/$new_policy_name" "$policy_json"
    # done
}

# Migration function for index templates
migrate_templates() {
    local local_file=$1
    local endpoint=$2
    local api_type=$3
    local missing=("${@:4}")
    local different=("${@:${#missing[@]}:4}")
    
    # Migrate missing templates with ignore_missing_component_templates flag
    for template in "${missing[@]}"; do
        echo -e "${BLUE}Migrating missing index template: $template${NC}"
        # Extract the index_template object for this template
        template_json=$(jq --arg t "$template" '.index_templates[] | select(.name==$t) | .index_template' "$local_file")
        
        # Process the template to remove component_templates if they exist
        if echo "$template_json" | jq -e 'has("composed_of")' > /dev/null; then
            echo -e "${YELLOW}Template uses component templates - removing references${NC}"
            template_json=$(echo "$template_json" | jq 'del(.composed_of)')
        fi
        
        # Check if the template uses time_series mode without routing_path
        if echo "$template_json" | jq -e '.settings["index.mode"] == "time_series" and (.settings["index.routing_path"] | not)' > /dev/null; then
            echo -e "${YELLOW}Template uses time_series mode without routing_path - adjusting settings${NC}"
            
            # Option 1: Remove time_series mode
