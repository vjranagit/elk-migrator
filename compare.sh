#!/bin/bash

# Find the latest export folder
latest_folder=$(ls -td elastic_export_* | head -1)

if [[ ! -d "$latest_folder/es_resources/cloud" || ! -d "$latest_folder/es_resources/local" ]]; then
  echo "Error: Could not find expected es_resources/cloud or es_resources/local in $latest_folder"
  exit 1
fi

CLOUD_ES="$latest_folder/es_resources/cloud"
LOCAL_ES="$latest_folder/es_resources/local"
CLOUD_KB="$latest_folder/kibana/cloud"
LOCAL_KB="$latest_folder/kibana/local"
CLOUD_SAVED="$latest_folder/cloud_saved_objects"
LOCAL_SAVED="$latest_folder/local_saved_objects"

resources=("cluster_settings.json" "ilm_policy.json" "logstash_pipelines.json" "index_templates.json" "security_roles.json" "snapshot_repos.json")
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

compare_templates() {
    local cloud_file="$CLOUD_ES/index_templates.json"
    local local_file="$LOCAL_ES/index_templates.json"

    echo -e "\n${YELLOW}=== Analyzing index_templates.json ===${NC}"

    cloud_names=$(jq -r '.index_templates[].name' "$cloud_file" | sort)
    local_names=$(jq -r '.index_templates[].name' "$local_file" | sort)

    missing_in_cloud=$(comm -23 <(echo "$local_names") <(echo "$cloud_names"))
    extra_in_cloud=$(comm -23 <(echo "$cloud_names") <(echo "$local_names"))
    common_names=$(comm -12 <(echo "$cloud_names") <(echo "$local_names"))

    echo -e "\n${GREEN}[+] Already in cloud:${NC}"
    echo "$common_names" | while read -r name; do
        [[ -z "$name" ]] && continue
        cloud_tpl=$(jq -S --arg name "$name" '.index_templates[] | select(.name==$name)' "$cloud_file")
        local_tpl=$(jq -S --arg name "$name" '.index_templates[] | select(.name==$name)' "$local_file")
        if diff <(echo "$cloud_tpl") <(echo "$local_tpl") &>/dev/null; then
            echo "  ✓ $name (identical)"
        else
            echo -e "  ${RED}⚠ $name (different)${NC}"
        fi
    done

    echo -e "\n${RED}[-] Missing in cloud (needs migration):${NC}"
    [ -n "$missing_in_cloud" ] && echo "$missing_in_cloud" || echo "  (none)"

    echo -e "\n${YELLOW}[!] Extra in cloud (not in local):${NC}"
    [ -n "$extra_in_cloud" ] && echo "$extra_in_cloud" || echo "  (none)"
}


compare_pipelines() {
    local cloud_file="$CLOUD_ES/logstash_pipelines.json"
    local local_file="$LOCAL_ES/logstash_pipelines.json"

    echo -e "\n${YELLOW}=== Analyzing logstash_pipelines.json ===${NC}"

    # Check if files exist and are not empty
    if [[ ! -s "$cloud_file" ]] || [[ ! -s "$local_file" ]]; then
        echo -e "${RED}❌ One or both pipeline files are missing or empty${NC}"
        return 1
    fi

    cloud_names=$(jq -r 'keys[]' "$cloud_file" | sort)
    local_names=$(jq -r 'keys[]' "$local_file" | sort)

    missing_in_cloud=$(comm -23 <(echo "$local_names") <(echo "$cloud_names"))
    extra_in_cloud=$(comm -23 <(echo "$cloud_names") <(echo "$local_names"))
    common_names=$(comm -12 <(echo "$cloud_names") <(echo "$local_names"))

    echo -e "\n${GREEN}[+] Already in cloud:${NC}"
    echo "$common_names" | while read -r name; do
        [[ -z "$name" ]] && continue
        # Compare pipeline configurations excluding metadata that might differ
        cloud_pipeline=$(jq -S --arg name "$name" '.[$name] | del(.last_modified, .username)' "$cloud_file")
        local_pipeline=$(jq -S --arg name "$name" '.[$name] | del(.last_modified, .username)' "$local_file")
        
        if diff <(echo "$cloud_pipeline") <(echo "$local_pipeline") &>/dev/null; then
            echo "  ✓ $name (identical)"
        else
            echo -e "  ${RED}⚠ $name (different configuration)${NC}"
            # Show brief difference summary
            local_desc=$(jq -r --arg name "$name" '.[$name].description // "No description"' "$local_file")
            cloud_desc=$(jq -r --arg name "$name" '.[$name].description // "No description"' "$cloud_file")
            if [[ "$local_desc" != "$cloud_desc" ]]; then
                echo "    → Description differs"
            fi
            
            local_pipeline_def=$(jq -r --arg name "$name" '.[$name].pipeline // ""' "$local_file")
            cloud_pipeline_def=$(jq -r --arg name "$name" '.[$name].pipeline // ""' "$cloud_file")
            if [[ "$local_pipeline_def" != "$cloud_pipeline_def" ]]; then
                echo "    → Pipeline definition differs"
            fi
        fi
    done

    echo -e "\n${RED}[-] Missing in cloud (needs migration):${NC}"
    if [ -n "$missing_in_cloud" ]; then
        echo "$missing_in_cloud" | while read -r name; do
            [[ -z "$name" ]] && continue
            desc=$(jq -r --arg name "$name" '.[$name].description // "No description"' "$local_file")
            echo "  • $name - $desc"
        done
    else
        echo "  (none)"
    fi

    echo -e "\n${YELLOW}[!] Extra in cloud (not in local):${NC}"
    if [ -n "$extra_in_cloud" ]; then
        echo "$extra_in_cloud" | while read -r name; do
            [[ -z "$name" ]] && continue
            desc=$(jq -r --arg name "$name" '.[$name].description // "No description"' "$cloud_file")
            echo "  • $name - $desc"
        done
    else
        echo "  (none)"
    fi
}

compare_resources() {
    local resource=$1
    local cloud_file="$CLOUD_ES/$resource"
    local local_file="$LOCAL_ES/$resource"

    echo -e "\n${YELLOW}=== Analyzing $resource ===${NC}"

    if [[ "$resource" == "index_templates.json" ]]; then
        compare_templates
        return
    elif [[ "$resource" == "logstash_pipelines.json" ]]; then    # <-- ADD THIS CONDITION
        compare_pipelines
        return
    fi

    # ... rest of the function remains the same
    cloud_keys=$(jq -r 'keys[]' "$cloud_file" | sort)
    local_keys=$(jq -r 'keys[]' "$local_file" | sort)

    missing_in_cloud=$(comm -23 <(echo "$local_keys") <(echo "$cloud_keys"))
    extra_in_cloud=$(comm -23 <(echo "$cloud_keys") <(echo "$local_keys"))
    common_keys=$(comm -12 <(echo "$cloud_keys") <(echo "$local_keys"))

    echo -e "\n${GREEN}[+] Already in cloud:${NC}"
    echo "$common_keys" | while read -r key; do
        [[ -z "$key" ]] && continue
        cloud_content=$(jq -S .["\"$key\""] "$cloud_file")
        local_content=$(jq -S .["\"$key\""] "$local_file")
        if diff <(echo "$cloud_content") <(echo "$local_content") &>/dev/null; then
            echo "  ✓ $key (identical)"
        else
            echo -e "  ${RED}⚠ $key (different)${NC}"
        fi
    done

    echo -e "\n${RED}[-] Missing in cloud (needs migration):${NC}"
    [ -n "$missing_in_cloud" ] && echo "$missing_in_cloud" || echo "  (none)"

    echo -e "\n${YELLOW}[!] Extra in cloud (not in local):${NC}"
    [ -n "$extra_in_cloud" ] && echo "$extra_in_cloud" || echo "  (none)"
}
compare_spaces() {
    echo -e "\n${YELLOW}=== Analyzing Kibana Spaces ===${NC}"
    cloud_spaces=$(jq -r '.[].id' "$CLOUD_KB/kibana_spaces.json" | sort)
    local_spaces=$(jq -r '.[].id' "$LOCAL_KB/kibana_spaces.json" | sort)

    missing_in_cloud=$(comm -23 <(echo "$local_spaces") <(echo "$cloud_spaces"))
    extra_in_cloud=$(comm -23 <(echo "$cloud_spaces") <(echo "$local_spaces"))
    common_spaces=$(comm -12 <(echo "$cloud_spaces") <(echo "$local_spaces"))

    echo -e "\n${GREEN}[+] Already in cloud:${NC}"
    [ -n "$common_spaces" ] && echo "$common_spaces" || echo "  (none)"

    echo -e "\n${RED}[-] Missing in cloud (needs migration):${NC}"
    [ -n "$missing_in_cloud" ] && echo "$missing_in_cloud" || echo "  (none)"

    echo -e "\n${YELLOW}[!] Extra in cloud (not in local):${NC}"
    [ -n "$extra_in_cloud" ] && echo "$extra_in_cloud" || echo "  (none)"
}

compare_saved_objects() {
    echo -e "\n${YELLOW}=== Analyzing Kibana Saved Objects (per space) ===${NC}"
    # List all saved object files for each env
    cloud_files=($(ls "$CLOUD_SAVED"/cloud_kibana_space_*_export.ndjson 2>/dev/null | xargs -n1 basename | sort))
    local_files=($(ls "$LOCAL_SAVED"/local_kibana_space_*_export.ndjson 2>/dev/null | xargs -n1 basename | sort))

    cloud_spaces=($(printf "%s\n" "${cloud_files[@]}" | sed -E 's/cloud_kibana_space_(.*)_export.ndjson/\1/' | sort))
