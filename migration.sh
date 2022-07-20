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
            
            if [ "$local_config" != "$cloud_config" ]; then
                pipelines_different+=("$pipeline")
            else
                echo -e "${GREEN}Pipeline '$pipeline' is identical in both environments${NC}"
            fi
        else
            # Pipeline doesn't exist in cloud
            pipelines_missing+=("$pipeline")
        fi
    done
    
    # Report findings
    total_to_migrate=$((${#pipelines_missing[@]} + ${#pipelines_different[@]}))
    
    if [ $total_to_migrate -eq 0 ]; then
        echo -e "${GREEN}No Logstash pipelines need migration.${NC}"
        return 0
    fi
    
    echo -e "${YELLOW}Logstash pipelines migration summary:${NC}"
    echo "  - Missing in cloud (${#pipelines_missing[@]}): ${pipelines_missing[*]}"
    echo "  - Different from cloud (${#pipelines_different[@]}): ${pipelines_different[*]}"
    echo
    
    # Show what will be created
    echo -e "${YELLOW}Pipelines that will be created with new names:${NC}"
    for pipeline in "${pipelines_missing[@]}"; do
        echo "  - $pipeline (new: $pipeline)"
    done
    for pipeline in "${pipelines_different[@]}"; do
        echo "  - $pipeline (new: migrated_${TIMESTAMP}_${pipeline})"
    done
    
    # Ask for migration
    read -p "Do you want to migrate these Logstash pipelines? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Migration skipped.${NC}"
        return 0
    fi
    
    # Migrate missing pipelines with original names
    for pipeline in "${pipelines_missing[@]}"; do
        echo -e "${BLUE}Creating missing pipeline: $pipeline${NC}"
        
        pipeline_json=$(jq --arg p "$pipeline" '.[$p]' "$local_pipelines_file")
        result=$(cloud_request "es" "PUT" "_logstash/pipeline/$pipeline" "$pipeline_json" "raw")
        
        # IMPROVED SUCCESS DETECTION
        # Check for various success indicators in the response
        if echo "$result" | jq -e '.acknowledged' > /dev/null 2>&1; then
            echo -e "${GREEN}✓ Pipeline '$pipeline' created successfully (acknowledged)${NC}"
        elif echo "$result" | jq -e '.created' > /dev/null 2>&1; then
            echo -e "${GREEN}✓ Pipeline '$pipeline' created successfully (created)${NC}"
        elif echo "$result" | jq -e '.result' > /dev/null 2>&1 && [[ $(echo "$result" | jq -r '.result') == "created" ]]; then
            echo -e "${GREEN}✓ Pipeline '$pipeline' created successfully (result: created)${NC}"
        elif echo "$result" | jq -e '.errors' > /dev/null 2>&1; then
            echo -e "${RED}✗ Failed to create pipeline '$pipeline': $(echo "$result" | jq -r '.errors')${NC}"
        elif echo "$result" | jq -e '.error' > /dev/null 2>&1; then
            echo -e "${RED}✗ Failed to create pipeline '$pipeline': $(echo "$result" | jq -r '.error.reason // .error')${NC}"
        else
            # If no clear error indicators, but also no success indicators, show the raw response
            echo -e "${YELLOW}? Uncertain result for pipeline '$pipeline'. Raw response:${NC}"
            echo "$result" | jq '.' 2>/dev/null || echo "$result"
            
            # Try to verify by fetching the pipeline back
            echo -e "${BLUE}Verifying pipeline creation by fetching it back...${NC}"
            verify_result=$(cloud_request "es" "GET" "_logstash/pipeline/$pipeline" "" "raw")
            if echo "$verify_result" | jq -e --arg p "$pipeline" '.[$p]' > /dev/null 2>&1; then
                echo -e "${GREEN}✓ Pipeline '$pipeline' verified - creation was successful${NC}"
            else
                echo -e "${RED}✗ Pipeline '$pipeline' verification failed - creation may have failed${NC}"
            fi
        fi
    done
    
    # Migrate different pipelines with new names
    for pipeline in "${pipelines_different[@]}"; do
        new_pipeline_name="migrated_${TIMESTAMP}_${pipeline}"
        echo -e "${BLUE}Creating pipeline with new name: $new_pipeline_name${NC}"
        
        pipeline_json=$(jq --arg p "$pipeline" '.[$p]' "$local_pipelines_file")
        result=$(cloud_request "es" "PUT" "_logstash/pipeline/$new_pipeline_name" "$pipeline_json" "raw")
        
        # IMPROVED SUCCESS DETECTION (same as above)
        if echo "$result" | jq -e '.acknowledged' > /dev/null 2>&1; then
            echo -e "${GREEN}✓ Pipeline '$new_pipeline_name' created successfully (acknowledged)${NC}"
        elif echo "$result" | jq -e '.created' > /dev/null 2>&1; then
            echo -e "${GREEN}✓ Pipeline '$new_pipeline_name' created successfully (created)${NC}"
        elif echo "$result" | jq -e '.result' > /dev/null 2>&1 && [[ $(echo "$result" | jq -r '.result') == "created" ]]; then
            echo -e "${GREEN}✓ Pipeline '$new_pipeline_name' created successfully (result: created)${NC}"
        elif echo "$result" | jq -e '.errors' > /dev/null 2>&1; then
            echo -e "${RED}✗ Failed to create pipeline '$new_pipeline_name': $(echo "$result" | jq -r '.errors')${NC}"
        elif echo "$result" | jq -e '.error' > /dev/null 2>&1; then
            echo -e "${RED}✗ Failed to create pipeline '$new_pipeline_name': $(echo "$result" | jq -r '.error.reason // .error')${NC}"
        else
            # If no clear error indicators, but also no success indicators, show the raw response
            echo -e "${YELLOW}? Uncertain result for pipeline '$new_pipeline_name'. Raw response:${NC}"
            echo "$result" | jq '.' 2>/dev/null || echo "$result"
            
            # Try to verify by fetching the pipeline back
            echo -e "${BLUE}Verifying pipeline creation by fetching it back...${NC}"
            verify_result=$(cloud_request "es" "GET" "_logstash/pipeline/$new_pipeline_name" "" "raw")
            if echo "$verify_result" | jq -e --arg p "$new_pipeline_name" '.[$p]' > /dev/null 2>&1; then
                echo -e "${GREEN}✓ Pipeline '$new_pipeline_name' verified - creation was successful${NC}"
            else
                echo -e "${RED}✗ Pipeline '$new_pipeline_name' verification failed - creation may have failed${NC}"
            fi
        fi
    done
    
    echo -e "${GREEN}Logstash pipeline migration completed.${NC}"
}
# Function to migrate index templates with new names
migrate_templates_as_new() {
    local export_dir=$1
    local local_templates_file="$export_dir/es_resources/local/index_templates.json"
    
    if [ ! -f "$local_templates_file" ]; then
        echo -e "${RED}Error: Index templates file not found at $local_templates_file${NC}"
        return 1
    fi
    
    echo -e "${BLUE}Analyzing index templates...${NC}"
    
    # Extract template names
    local_template_names=$(jq -r '.index_templates[].name' "$local_templates_file")
    
    # Prepare to migrate all templates with new names
    templates_to_migrate=()
    for template in $local_template_names; do
        # Skip built-in templates
        if [[ "$template" == ".monitoring-"* || "$template" == ".watch"* || "$template" == ".ml-"* ]]; then
            echo -e "${YELLOW}Skipping built-in template: $template${NC}"
            continue
        fi
        
        templates_to_migrate+=("$template")
    done
    
    # Report findings
    if [ ${#templates_to_migrate[@]} -eq 0 ]; then
        echo -e "${GREEN}No custom index templates to migrate.${NC}"
        return 0
    fi
    
    echo -e "${YELLOW}Index templates to migrate as new (${#templates_to_migrate[@]}):${NC}"
    for template in "${templates_to_migrate[@]}"; do
        echo "  - $template will be created as migrated_${TIMESTAMP}_${template}"
    done
    
    # Ask for migration
    read -p "Do you want to migrate these index templates to cloud with new names? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Migration skipped.${NC}"
        return 0
    fi
    
    # Migrate templates with new names
    for template in "${templates_to_migrate[@]}"; do
        new_template_name="migrated_${TIMESTAMP}_${template}"
        echo -e "${BLUE}Migrating index template as: $new_template_name${NC}"
        
        # Get template JSON and update the name
        template_json=$(jq --arg t "$template" --arg nt "$new_template_name" \
            '.index_templates[] | select(.name==$t) | .index_template' "$local_templates_file" | \
            jq --arg nt "$new_template_name" '.index_patterns = [.index_patterns[] | sub("^"; "migrated_")] | .template.settings.index.lifecycle.name = .template.settings.index.lifecycle.name // "" | sub("^"; "migrated_'$TIMESTAMP'_")')
        
        cloud_request "es" "PUT" "_index_template/$new_template_name" "$template_json"
    done
    
    echo -e "${GREEN}Index template migration completed.${NC}"
}

# Function to migrate security roles with new names
migrate_roles_as_new() {
    local export_dir=$1
    local local_roles_file="$export_dir/es_resources/local/security_roles.json"
    
    if [ ! -f "$local_roles_file" ]; then
        echo -e "${RED}Error: Security roles file not found at $local_roles_file${NC}"
        return 1
    fi
    
    echo -e "${BLUE}Analyzing security roles...${NC}"
    
    # Extract role names
    local_role_names=$(jq -r 'keys[]' "$local_roles_file")
    
    # Prepare to migrate all roles with new names
    roles_to_migrate=()
    for role in $local_role_names; do
        # Skip built-in roles
        if [[ "$role" == "superuser" || "$role" == "kibana_system" || "$role" == "apm_system" || 
              "$role" == "logstash_system" || "$role" == "beats_system" || 
              "$role" == "remote_monitoring_collector" || "$role" == "remote_monitoring_agent" ]]; then
            echo -e "${YELLOW}Skipping built-in role: $role${NC}"
            continue
        fi
        
        roles_to_migrate+=("$role")
    done
    
    # Report findings
    if [ ${#roles_to_migrate[@]} -eq 0 ]; then
        echo -e "${GREEN}No custom security roles to migrate.${NC}"
        return 0
    fi
    
    echo -e "${YELLOW}Security roles to migrate as new (${#roles_to_migrate[@]}):${NC}"
    for role in "${roles_to_migrate[@]}"; do
        echo "  - $role will be created as migrated_${TIMESTAMP}_${role}"
    done
    
    # Ask for migration
    read -p "Do you want to migrate these security roles to cloud with new names? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Migration skipped.${NC}"
        return 0
    fi
    
    # Migrate roles with new names
    for role in "${roles_to_migrate[@]}"; do
        new_role_name="migrated_${TIMESTAMP}_${role}"
        echo -e "${BLUE}Migrating security role as: $new_role_name${NC}"
        
        # Get role JSON and update any index patterns to match the new migrated indices
        role_json=$(jq --arg r "$role" '.[$r]' "$local_roles_file" | \
            jq 'if .indices then .indices = [.indices[] | .names = [.names[] | sub("^"; "migrated_")]] else . end')
        
        cloud_request "es" "PUT" "_security/role/$new_role_name" "$role_json"
    done
    
    echo -e "${GREEN}Security role migration completed.${NC}"
}

# Function to migrate spaces with new names
migrate_spaces_as_new() {
    local export_dir=$1
    local local_spaces_file="$export_dir/kibana/local/kibana_spaces.json"
    
    if [ ! -f "$local_spaces_file" ]; then
        echo -e "${RED}Error: Kibana spaces file not found at $local_spaces_file${NC}"
        return 1
    fi
    
    echo -e "${BLUE}Analyzing Kibana spaces...${NC}"
    
    # Extract space IDs
    local_space_ids=$(jq -r '.[].id' "$local_spaces_file")
    
    # Prepare to migrate all spaces with new names, except default
    spaces_to_migrate=()
    for space in $local_space_ids; do
        # Skip default space
        if [[ "$space" == "default" ]]; then
            echo -e "${YELLOW}Skipping default space${NC}"
            continue
        fi
        
        spaces_to_migrate+=("$space")
    done
    
    # Report findings
    if [ ${#spaces_to_migrate[@]} -eq 0 ]; then
        echo -e "${GREEN}No custom Kibana spaces to migrate.${NC}"
        return 0
    fi
    
    echo -e "${YELLOW}Kibana spaces to migrate as new (${#spaces_to_migrate[@]}):${NC}"
    for space in "${spaces_to_migrate[@]}"; do
        echo "  - $space will be created as migrated_${TIMESTAMP}_${space}"
    done
    
    # Ask for migration
    read -p "Do you want to migrate these Kibana spaces to cloud with new names? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Migration skipped.${NC}"
        return 0
    fi
    
    # Migrate spaces with new names
    for space in "${spaces_to_migrate[@]}"; do
        new_space_id="migrated_${TIMESTAMP}_${space}"
        echo -e "${BLUE}Migrating Kibana space as: $new_space_id${NC}"
        
        # Get space JSON and update the ID and name
        space_json=$(jq --arg s "$space" --arg ns "$new_space_id" \
            '.[] | select(.id==$s) | .id = $ns | .name = "Migrated " + .name' "$local_spaces_file")
        
        cloud_request "kb" "POST" "api/spaces/space" "$space_json"
    done
    
    echo -e "${GREEN}Kibana space migration completed.${NC}"
}

# Function to migrate saved objects with new IDs
migrate_saved_objects_as_new() {
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
    
    # Ask for migration
    read -p "Do you want to import these saved objects to cloud with new IDs? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Import skipped.${NC}"
        return 0
    fi
    
    # Create a temp directory for transformed files
    temp_dir=$(mktemp -d)
    echo -e "${BLUE}Created temporary directory for transformed objects: $temp_dir${NC}"
    
    # Import saved objects for each space
    for file in $export_files; do
        space=$(echo "$file" | sed 's/.*local_kibana_space_\(.*\)_export.ndjson/\1/')
        
        # Determine target space
        new_space="${space}"
        if [[ "$space" != "default" ]]; then
            new_space="migrated_${TIMESTAMP}_${space}"
            
            # Check if the space exists, create if it doesn't
            cloud_space=$(cloud_request "kb" "GET" "api/spaces/space/$new_space" "" "raw")
            if ! echo "$cloud_space" | jq -e '.id' > /dev/null 2>&1; then
                echo -e "${YELLOW}Space '$new_space' doesn't exist in cloud. Creating it first...${NC}"
                default_space_json='{"id":"'$new_space'","name":"Migrated '$space'","description":"Migrated from local environment"}'
                cloud_request "kb" "POST" "api/spaces/space" "$default_space_json"
            fi
        fi
        
        # Transform objects
        transformed_file="${temp_dir}/transformed_${space}.ndjson"
        echo "" > "$transformed_file"  # Create empty file
        
        transform_saved_objects "$file" "$transformed_file" "migrated_${TIMESTAMP}"
        
        # Import transformed objects
        post_import_saved_objects "$new_space" "$transformed_file"
    done
    
    echo -e "${GREEN}Saved objects migration completed.${NC}"
    echo -e "${BLUE}Cleaning up temporary files...${NC}"
    rm -rf "$temp_dir"
}

# Function to migrate cluster settings as new settings (selective approach)
migrate_cluster_settings_selective() {
    local export_dir=$1
    local local_settings_file="$export_dir/es_resources/local/cluster_settings.json"
    
    if [ ! -f "$local_settings_file" ]; then
