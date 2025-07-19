#!/bin/bash

# Elasticsearch Migration Script v3
# Creates missing resources and creates prefixed copies of different resources
# Resolves issue with version field in ILM policies

# Colors for output
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# Cloud endpoints
CLOUD_ES_URL="https://aad95ab1d4034bc6a296fe71dd50e397.us-east-1.aws.found.io:443"
CLOUD_KIBANA="https://gt-elastic-cloud.kb.us-east-1.aws.found.io"

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
            template_json=$(echo "$template_json" | jq 'del(.settings["index.mode"])')
            
            # Option 2 (alternative): Add a default routing path if you prefer to keep time series mode
            # Use this instead of the above line if you want to preserve time series functionality
            # template_json=$(echo "$template_json" | jq '.settings["index.routing_path"] = ["@timestamp"]')
        fi
        
        # Attempt to import the template
        response=$(cloud_request "$api_type" "PUT" "${endpoint}/$template" "$template_json" 2>&1)
        
        # Check if the import was successful
        if [[ "$response" == *"\"acknowledged\":true"* ]]; then
            echo -e "${GREEN}Successfully imported template: $template${NC}"
        else
            echo -e "${RED}Failed to import template: $template${NC}"
            echo -e "${RED}$response${NC}"
            # Log the modified JSON for debugging
            # echo "Template JSON:"  failed
            # echo "$template_json"  failed
            echo "$template"  failed_templates
        fi
    done
    # for template in "${missing[@]}"; do
    #     echo -e "${BLUE}Migrating missing index template: $template${NC}"
    #     # Extract the index_template object for this template
    #     template_json=$(jq --arg t "$template" '.index_templates[] | select(.name==$t) | .index_template' "$local_file")
        
    #     # Process the template to remove component_templates if they exist
    #     if echo "$template_json" | jq -e 'has("composed_of")' > /dev/null; then
    #         echo -e "${YELLOW}Template uses component templates - removing references${NC}"
    #         template_json=$(echo "$template_json" | jq 'del(.composed_of)')
    #     fi
        
    #     # Attempt to import the template
    #     response=$(cloud_request "$api_type" "PUT" "${endpoint}/$template" "$template_json" 2>&1)
        
    #     # Check if the import was successful
    #     if [[ "$response" == *"\"acknowledged\":true"* ]]; then
    #         echo -e "${GREEN}Successfully imported template: $template${NC}"
    #     else
    #         echo -e "${RED}Failed to import template: $template${NC}"
    #         echo -e "${RED}$response${NC}"
    #         # You may want to log failures for later investigation
    #         echo "$template" failed# >> failed_templates.log
    #     fi
    # done

    # for template in "${missing[@]}"; do
    #     echo -e "${BLUE}Migrating missing index template: $template${NC}"
    #     template_json=$(jq --arg t "$template" '.index_templates[] | select(.name==$t) | .index_template' "$local_file")
    #     cloud_request "$api_type" "PUT" "${endpoint}/$template" "$template_json"
    # done

    # # Create prefixed copies of different templates
    # for template in "${different[@]}"; do
    #     new_template_name="migrated_${TIMESTAMP}_${template}"
    #     echo -e "${BLUE}Creating new index template as: $new_template_name${NC}"
    #     template_json=$(jq --arg t "$template" --arg new "$new_template_name" '.index_templates[] | select(.name==$t) | .index_template | .index_patterns = [.index_patterns[0] + "-" + $new]' "$local_file")
    #     cloud_request "$api_type" "PUT" "${endpoint}/$new_template_name" "$template_json"
    # done
}

# Migration function for security roles
migrate_roles() {
    local local_file=$1
    local endpoint=$2
    local api_type=$3
    local missing=("${@:4}")
    local different=("${@:${#missing[@]}:4}")
    
    # Migrate missing roles
    for role in "${missing[@]}"; do
        echo -e "${BLUE}Migrating missing security role: $role${NC}"
        role_json=$(jq --arg r "$role" '.[$r]' "$local_file")
        cloud_request "$api_type" "PUT" "${endpoint}/$role" "$role_json"
    done

    # Create prefixed copies of different roles
    # for role in "${different[@]}"; do
    #     new_role_name="migrated_${TIMESTAMP}_${role}"
    #     echo -e "${BLUE}Creating new security role as: $new_role_name${NC}"
    #     role_json=$(jq --arg r "$role" '.[$r]' "$local_file")
    #     cloud_request "$api_type" "PUT" "${endpoint}/$new_role_name" "$role_json"
    # done
}

# Migration function for Kibana spaces
migrate_spaces() {
    local local_file=$1
    local endpoint=$2
    local api_type=$3
    local missing=("${@:4}")
    local different=("${@:${#missing[@]}:4}")
    
    # Migrate missing spaces
    for space in "${missing[@]}"; do
        echo -e "${BLUE}Migrating missing Kibana space: $space${NC}"
        space_json=$(jq --arg s "$space" '.[] | select(.id==$s)' "$local_file")
        cloud_request "$api_type" "POST" "$endpoint" "$space_json"
    done

    # Create prefixed copies of different spaces
    for space in "${different[@]}"; do
        new_space_name="migrated_${TIMESTAMP}_${space}"
        echo -e "${BLUE}Creating new Kibana space as: $new_space_name${NC}"
        space_json=$(jq --arg s "$space" --arg new "$new_space_name" '.[] | select(.id==$s) | .id = $new | .name = $new' "$local_file")
        cloud_request "$api_type" "POST" "$endpoint" "$space_json"
    done
}

# Function to compare and migrate saved objects
compare_migrate_saved_objects() {
    local export_dir=$1
    local saved_objects_dir="$export_dir/local_saved_objects"
    
    if [ ! -d "$saved_objects_dir" ]; then
        echo -e "${RED}Error: Saved objects directory not found at $saved_objects_dir${NC}"
        return 1
    fi
    
    echo -e "${BLUE}Analyzing Kibana saved objects...${NC}"
    
    # Get all export files
    export_files=$(find "$saved_objects_dir" -name "local_kibana_space_*_export.ndjson")
    
    if [ -z "$export_files" ]; then
        echo -e "${YELLOW}No saved objects export files found.${NC}"
        return 0
    fi
    
    echo -e "${YELLOW}Found $(echo "$export_files" | wc -l) saved objects export files:${NC}"
    for file in $export_files; do
        space=$(echo "$file" | sed 's/.*local_kibana_space_\(.*\)_export.ndjson/\1/')
        count=$(grep -c "" "$file")
        echo "  - Space '$space': $count objects"
    done
    
    # Ask for migration confirmation
    read -p "Do you want to import these saved objects to cloud? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Import skipped.${NC}"
        return 0
    fi
    
    # Import saved objects for each space
    for file in $export_files; do
        space=$(echo "$file" | sed 's/.*local_kibana_space_\(.*\)_export.ndjson/\1/')
        
        # Check if the space exists, create if it doesn't
        cloud_space=$(cloud_request "kb" "GET" "api/spaces/space/$space" "" "raw")
        if ! echo "$cloud_space" | jq -e '.id' > /dev/null 2>&1; then
            echo -e "${YELLOW}Space '$space' doesn't exist in cloud. Creating it first...${NC}"
            default_space_json='{"id":"'$space'","name":"'$space'","description":"Migrated from local environment"}'
            cloud_request "kb" "POST" "api/spaces/space" "$default_space_json"
        fi
        
        # Import saved objects without overwriting existing ones
        echo -e "${BLUE}Importing saved objects to space '$space'...${NC}"
        post_import_saved_objects "$space" "$file"
    done
    
    echo -e "${GREEN}Saved objects migration completed.${NC}"
}

# Help function
show_help() {
    echo "Usage: $0 [options]"
    echo
    echo "Options:"
    echo "  all              Run all comparisons and migrations"
    echo "  dir <path>       Specify the export directory to use (default: latest)"
    echo "  ilm              Compare and migrate ILM policies"
    echo "  templates        Compare and migrate index templates"
    echo "  roles            Compare and migrate security roles"
    echo "  spaces           Compare and migrate Kibana spaces"
    echo "  objects          Compare and migrate Kibana saved objects"
    echo "  help             Show this help message"
}

# Main function to run all comparisons
run_all_comparisons() {
    export_dir=$1
    
    echo -e "${BLUE}=== Starting migration analysis ===${NC}"
    
    # Set up resource comparison params for each resource type
    
    # ILM policies
    compare_resources "ILM policies" \
                     "$export_dir/es_resources/local/ilm_policy.json" \
                     "_ilm/policy" \
                     "es" \
                     "keys[]" \
                     '.[$id]' \
                     "migrate_ilm"
    
    # Index templates
    compare_resources "index templates" \
                     "$export_dir/es_resources/local/index_templates.json" \
                     "_index_template" \
                     "es" \
                     ".index_templates[].name" \
                     '.index_templates[] | select(.name==$id) | .index_template' \
                     "migrate_templates"
    
    # Security roles
    compare_resources "security roles" \
                     "$export_dir/es_resources/local/security_roles.json" \
                     "_security/role" \
                     "es" \
                     "keys[]" \
                     '.[$id]' \
                     "migrate_roles"
    
    # Kibana spaces
    compare_resources "Kibana spaces" \
                     "$export_dir/kibana/local/kibana_spaces.json" \
                     "api/spaces/space" \
                     "kb" \
                     ".[].id" \
                     '.[] | select(.id==$id) | del(._reserved, .updatedAt, .created_at, .updated_at)' \
                     "migrate_spaces"
    
    # Saved objects
    compare_migrate_saved_objects "$export_dir"
    
    echo -e "${GREEN}=== Migration analysis and execution completed ===${NC}"
}

# Main execution
if [ -z "$CAPI_KEY" ]; then
    echo -e "${RED}Error: CAPI_KEY environment variable not set.${NC}"
    echo "Please set it with: export CAPI_KEY=your_cloud_api_key"
    exit 1
fi

if [ -z "$CCAPI_KEY" ] && [ "$1" == "objects" ] || [ "$1" == "all" ]; then
    echo -e "${YELLOW}Warning: CCAPI_KEY environment variable not set.${NC}"
    echo "Set it with: export CCAPI_KEY=your_cloud_kibana_api_key"
    echo "Saved objects migration may fail without this key."
fi

if [ $# -eq 0 ]; then
    show_help
    exit 0
fi

export_dir=""
run_ilm=false; run_templates=false; run_roles=false; 
run_spaces=false; run_objects=false; run_all=false

# Parse arguments
i=1
while [ $i -le $# ]; do
    arg="${!i}"
    case "$arg" in
        "all") run_all=true ;;
        "dir") 
            i=$((i+1))
            if [ $i -le $# ]; then
                export_dir="${!i}"
                [ ! -d "$export_dir" ] && echo -e "${RED}Error: Directory $export_dir does not exist.${NC}" && exit 1
            else
                echo -e "${RED}Error: No directory specified after 'dir'.${NC}"
                show_help; exit 1
            fi ;;
        "ilm") run_ilm=true ;;
        "templates") run_templates=true ;;
        "roles") run_roles=true ;;
        "spaces") run_spaces=true ;;
        "objects") run_objects=true ;;
        "help") show_help; exit 0 ;;
        *) echo -e "${RED}Error: Unknown option '$arg'.${NC}"; show_help; exit 1 ;;
    esac
    i=$((i+1))
done

# If no export directory specified, find the latest
[ -z "$export_dir" ] && export_dir=$(find_latest_export) && echo -e "${BLUE}Using latest export directory: $export_dir${NC}"

# Run requested comparisons
if [ "$run_all" = true ]; then
    run_all_comparisons "$export_dir"
else
    [ "$run_ilm" = true ] && compare_resources "ILM policies" "$export_dir/es_resources/local/ilm_policy.json" "_ilm/policy" "es" "keys[]" '.[$id]' "migrate_ilm"
    [ "$run_templates" = true ] && compare_resources "index templates" "$export_dir/es_resources/local/index_templates.json" "_index_template" "es" ".index_templates[].name" '.index_templates[] | select(.name==$id) | .index_template' "migrate_templates"
    [ "$run_roles" = true ] && compare_resources "security roles" "$export_dir/es_resources/local/security_roles.json" "_security/role" "es" "keys[]" '.[$id]' "migrate_roles"
    [ "$run_spaces" = true ] && compare_resources "Kibana spaces" "$export_dir/kibana/local/kibana_spaces.json" "api/spaces/space" "kb" ".[].id" '.[] | select(.id==$id) | del(._reserved, .updatedAt, .created_at, .updated_at)' "migrate_spaces"
    [ "$run_objects" = true ] && compare_migrate_saved_objects "$export_dir"
fi