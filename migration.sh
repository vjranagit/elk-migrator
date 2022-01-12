#!/bin/bash

# Elasticsearch Migration Analysis & Import Script (Create New Object Version)
# This script compares exported Elasticsearch/Kibana resources with a cloud environment
# and facilitates migration by creating new objects instead of overwriting existing ones

# Prerequisites: jq installed, $OAPI_KEY (on-prem) and $CAPI_KEY (cloud) set in your environment





# need to add the function to import missing with out new names and ony import already existings which are different with the new name 

# Colors for better readability
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Current timestamp for naming new objects
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# Find the latest export directory
find_latest_export() {
    latest_dir=$(find . -maxdepth 1 -type d -name "elastic_export_*" | sort -r | head -n1)
    if [ -z "$latest_dir" ]; then
        echo -e "${RED}Error: No export directory found. Run the export script first.${NC}"
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
    elif [ "$method" == "DELETE" ]; then
        response=$(curl -s -X DELETE -H "Authorization: ApiKey $CAPI_KEY" "$base_url/$endpoint")
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

# Transform saved objects for import without overwriting
transform_saved_objects() {
    local input_file=$1
    local output_file=$2
    local prefix=$3
    
    echo -e "${BLUE}Transforming saved objects with prefix: $prefix${NC}"
    
    # Process line by line to modify each saved object
    while IFS= read -r line; do
        # Parse the JSON object
        obj=$(echo "$line" | jq '.')
        
        # Extract the id and type
        id=$(echo "$obj" | jq -r '.id')
        type=$(echo "$obj" | jq -r '.type')
        
        # Create a new ID with prefix
        new_id="${prefix}_${id}"
        
        # Update the ID
        new_obj=$(echo "$obj" | jq --arg new_id "$new_id" '.id = $new_id')
        
        # If it has references, update them too
        if echo "$new_obj" | jq -e '.references' > /dev/null 2>&1; then
            new_obj=$(echo "$new_obj" | jq --arg prefix "$prefix" '.references = [.references[] | .id = ($prefix + "_" + .id)]')
        fi
        
        # Append to output file
        echo "$new_obj" >> "$output_file"
    done < "$input_file"
    
    echo -e "${GREEN}Transformation completed: $(wc -l < "$output_file") objects transformed${NC}"
}

# Post-import multipart/form-data request for saved objects
post_import_saved_objects() {
    local space=$1
    local file_path=$2

    echo -e "${BLUE}Importing saved objects to space '$space'...${NC}"
    
    response=$(curl -s -X POST "${CLOUD_KIBANA}/s/${space}/api/saved_objects/_import" \
      -H "kbn-xsrf: true" \
      -H "Authorization: ApiKey ${CAPI_KEY}" \
      --form file=@"$file_path")
    
    # Check for errors
    if echo "$response" | jq -e '.errors' > /dev/null 2>&1; then
        echo -e "${YELLOW}Import completed with some errors:${NC}"
        echo "$response" | jq '.errors'
        return 1
    else
        echo -e "${GREEN}Import successful!${NC}"
        echo "$response" | jq '.success'
        return 0
    fi
}

# Function to migrate ILM policies with new names
migrate_ilm_as_new() {
    local export_dir=$1
    local local_ilm_file="$export_dir/es_resources/local/ilm_policy.json"
    
    if [ ! -f "$local_ilm_file" ]; then
        echo -e "${RED}Error: ILM policy file not found at $local_ilm_file${NC}"
        return 1
    fi
    
    echo -e "${BLUE}Analyzing ILM policies...${NC}"
    
    # Get cloud ILM policies
    cloud_ilm=$(cloud_request "es" "GET" "_ilm/policy" "" "raw")
    
    # Extract policy names
    local_policies=$(jq -r 'keys[]' "$local_ilm_file")
    cloud_policies=$(echo "$cloud_ilm" | jq -r 'keys[]')
    
    # Prepare to migrate all policies with new names
    policies_to_migrate=()
    for policy in $local_policies; do
        # Skip built-in policies
        if [[ "$policy" == "watch-history-ilm-policy" || "$policy" == "ml-size-based-ilm-policy" || "$policy" == "logs" || "$policy" == "metrics" ]]; then
            echo -e "${YELLOW}Skipping built-in policy: $policy${NC}"
            continue
        fi
        
        policies_to_migrate+=("$policy")
    done
    
    # Report findings
    if [ ${#policies_to_migrate[@]} -eq 0 ]; then
        echo -e "${GREEN}No custom ILM policies to migrate.${NC}"
        return 0
    fi
    
    echo -e "${YELLOW}ILM policies to migrate as new (${#policies_to_migrate[@]}):${NC}"
    for policy in "${policies_to_migrate[@]}"; do
        echo "  - $policy will be created as migrated_${TIMESTAMP}_${policy}"
    done
    
    # Ask for migration
    read -p "Do you want to migrate these ILM policies to cloud with new names? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Migration skipped.${NC}"
        return 0
    fi
    
    # Migrate policies with new names
    for policy in "${policies_to_migrate[@]}"; do
        new_policy_name="migrated_${TIMESTAMP}_${policy}"
        echo -e "${BLUE}Migrating ILM policy as: $new_policy_name${NC}"
        
        policy_json=$(jq --arg p "$policy" '.[$p]' "$local_ilm_file")
        cloud_request "es" "PUT" "_ilm/policy/$new_policy_name" "$policy_json"
    done
    
    echo -e "${GREEN}ILM policy migration completed.${NC}"
}


migrate_pipelines_as_new() {
    local export_dir=$1
    local local_pipelines_file="$export_dir/es_resources/local/logstash_pipelines.json"
    
    if [ ! -f "$local_pipelines_file" ]; then
        echo -e "${RED}Error: Logstash pipelines file not found at $local_pipelines_file${NC}"
        return 1
    fi
    
    echo -e "${BLUE}Analyzing Logstash pipelines...${NC}"
    
    # Get cloud Logstash pipelines
    cloud_pipelines=$(cloud_request "es" "GET" "_logstash/pipeline" "" "raw")
    
    # Extract pipeline names
    local_pipeline_names=$(jq -r 'keys[]' "$local_pipelines_file")
    cloud_pipeline_names=$(echo "$cloud_pipelines" | jq -r 'keys[]')
    
    # Prepare arrays for migration
    pipelines_missing=()
    pipelines_different=()
    
    # Analyze each local pipeline
    for pipeline in $local_pipeline_names; do
        # Skip empty pipeline names
        if [ -z "$pipeline" ] || [ "$pipeline" == "null" ]; then
            continue
        fi
        
        # Check if pipeline exists in cloud
        if echo "$cloud_pipeline_names" | grep -q "^${pipeline}$"; then
            # Pipeline exists, check if it's different
            local_pipeline_content=$(jq --arg p "$pipeline" '.[$p]' "$local_pipelines_file")
            cloud_pipeline_content=$(echo "$cloud_pipelines" | jq --arg p "$pipeline" '.[$p]')
            
            # Compare pipeline configurations (excluding metadata that might differ)
            local_config=$(echo "$local_pipeline_content" | jq 'del(.last_modified, .username)')
            cloud_config=$(echo "$cloud_pipeline_content" | jq 'del(.last_modified, .username)')
            
