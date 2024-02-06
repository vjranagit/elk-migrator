#!/bin/bash

# Find the latest export folder
latest_folder=$(ls -td elastic_export_* | head -1)

if [[ ! -d "$latest_folder" ]]; then
  echo "Error: Could not find export folder"
  exit 1
fi

CLOUD_KB="$latest_folder/kibana/cloud"
LOCAL_KB="$latest_folder/kibana/local"
CLOUD_SAVED="$latest_folder/cloud_saved_objects"
LOCAL_SAVED="$latest_folder/local_saved_objects"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to count objects by type in an ndjson file
count_objects_by_type() {
    local file="$1"
    if [[ ! -f "$file" || ! -s "$file" ]]; then
        echo "{}"
        return
    fi
    
    # Check if file has valid JSON content
    if ! head -1 "$file" | jq . >/dev/null 2>&1; then
        echo "{}"
        return
    fi
    
    # Count objects by type, excluding references
    local types=$(jq -r 'select(.type != null) | .type' "$file" 2>/dev/null)
    
    if [[ -z "$types" ]]; then
        echo "{}"
        return
    fi
    
    local counts=$(echo "$types" | sort | uniq -c)
    
    if [[ -z "$counts" ]]; then
        echo "{}"
        return
    fi
    
    # Build JSON object from counts
    local result="{"
    local first=true
    
    while read -r count type; do
        if [[ -n "$type" ]]; then
            if [[ "$first" == true ]]; then
                first=false
            else
                result="$result,"
            fi
            result="$result\"$type\":$count"
        fi
    done <<< "$counts"
    
    result="$result}"
    echo "$result"
}

# Function to get object names by type
get_objects_by_type() {
    local file="$1"
    local object_type="$2"
    if [[ ! -f "$file" || ! -s "$file" ]]; then
        echo "[]"
        return
    fi
    
    # Check if file has valid JSON content
    if ! head -1 "$file" | jq . >/dev/null 2>&1; then
        echo "[]"
        return
    fi
    
    local objects=$(jq -r --arg type "$object_type" 'select(.type == $type) | .attributes.title // .id' "$file" 2>/dev/null)
    
    if [[ -z "$objects" ]]; then
        echo "[]"
        return
    fi
    
    # Build JSON array from objects
    local result="["
    local first=true
    
    while read -r name; do
        if [[ -n "$name" ]]; then
            if [[ "$first" == true ]]; then
                first=false
            else
                result="$result,"
            fi
            # Escape quotes in the name
            name=$(echo "$name" | sed 's/"/\\"/g')
            result="$result\"$name\""
        fi
    done <<< "$(echo "$objects" | sort)"
    
    result="$result]"
    echo "$result"
}

compare_space_objects() {
    local space_name="$1"
    local cloud_file="$CLOUD_SAVED/cloud_kibana_space_${space_name}_export.ndjson"
    local local_file="$LOCAL_SAVED/local_kibana_space_${space_name}_export.ndjson"
    
    echo -e "\n${BLUE}=== Space: $space_name ===${NC}"
    
    # Check if files exist and have content
    local cloud_exists=false
    local local_exists=false
    
    if [[ -f "$cloud_file" && -s "$cloud_file" ]]; then
        if head -1 "$cloud_file" | jq . >/dev/null 2>&1; then
            cloud_exists=true
        fi
    fi
    
    if [[ -f "$local_file" && -s "$local_file" ]]; then
        if head -1 "$local_file" | jq . >/dev/null 2>&1; then
            local_exists=true
        fi
    fi
    
    if [[ "$cloud_exists" == false && "$local_exists" == false ]]; then
        echo -e "${RED}❌ No valid objects found in either environment${NC}"
        return
    fi
    
    if [[ "$cloud_exists" == false ]]; then
        echo -e "${RED}❌ No valid objects found in cloud environment${NC}"
        if [[ "$local_exists" == true ]]; then
            echo -e "${YELLOW}⚠ Local objects exist but need migration${NC}"
        fi
        return
    fi
    
    if [[ "$local_exists" == false ]]; then
        echo -e "${RED}❌ No valid objects found in local environment${NC}"
        if [[ "$cloud_exists" == true ]]; then
            echo -e "${YELLOW}⚠ Cloud objects exist (may be cloud-specific)${NC}"
        fi
        return
    fi
    
    # Get object counts for both environments
    cloud_counts=$(count_objects_by_type "$cloud_file")
    local_counts=$(count_objects_by_type "$local_file")
    
    # Get all object types from both environments - handle empty JSON properly
    all_types=""
    if [[ "$cloud_counts" != "{}" ]]; then
        cloud_types=$(echo "$cloud_counts" | jq -r 'keys[]' 2>/dev/null || echo "")
        all_types="$cloud_types"
    fi
    if [[ "$local_counts" != "{}" ]]; then
        local_types=$(echo "$local_counts" | jq -r 'keys[]' 2>/dev/null || echo "")
        if [[ -n "$all_types" ]]; then
            all_types="$all_types"$'\n'"$local_types"
        else
            all_types="$local_types"
        fi
    fi
    
    # Remove empty lines and sort uniquely
    all_types=$(echo "$all_types" | grep -v '^$' | sort -u)
    
    if [[ -z "$all_types" ]]; then
        echo -e "${RED}❌ No objects found in either environment${NC}"
        return
    fi
    
    echo -e "\n${YELLOW}Object Summary:${NC}"
    echo "$all_types" | while read -r obj_type; do
        [[ -z "$obj_type" ]] && continue
        
        cloud_count=$(echo "$cloud_counts" | jq -r ".\"$obj_type\" // 0")
        local_count=$(echo "$local_counts" | jq -r ".\"$obj_type\" // 0")
        
        printf "  %-20s Cloud: %3d | Local: %3d" "$obj_type" "$cloud_count" "$local_count"
        
        if [[ "$cloud_count" -eq "$local_count" && "$cloud_count" -gt 0 ]]; then
            echo -e " ${GREEN}✓${NC}"
        elif [[ "$cloud_count" -lt "$local_count" ]]; then
            echo -e " ${RED}⚠ Missing: $((local_count - cloud_count))${NC}"
        elif [[ "$cloud_count" -gt "$local_count" ]]; then
            echo -e " ${YELLOW}⚠ Extra: $((cloud_count - local_count))${NC}"
        else
            echo ""
        fi
    done
    
    # Detailed comparison for each object type
    echo "$all_types" | while read -r obj_type; do
        [[ -z "$obj_type" ]] && continue
        
        cloud_objects=$(get_objects_by_type "$cloud_file" "$obj_type")
        local_objects=$(get_objects_by_type "$local_file" "$obj_type")
        
        cloud_names=$(echo "$cloud_objects" | jq -r '.[]' | sort)
        local_names=$(echo "$local_objects" | jq -r '.[]' | sort)
        
        if [[ -z "$cloud_names" && -z "$local_names" ]]; then
            continue
        fi
        
        missing_in_cloud=$(comm -23 <(echo "$local_names") <(echo "$cloud_names"))
        extra_in_cloud=$(comm -23 <(echo "$cloud_names") <(echo "$local_names"))
        common_objects=$(comm -12 <(echo "$cloud_names") <(echo "$local_names"))
        
        echo -e "\n${YELLOW}--- $obj_type Objects ---${NC}"
        
        if [[ -n "$common_objects" ]]; then
            echo -e "${GREEN}[+] Already in cloud:${NC}"
            echo "$common_objects" | while read -r name; do
                [[ -z "$name" ]] && continue
                echo "  ✓ $name"
            done
        fi
        
        if [[ -n "$missing_in_cloud" ]]; then
            echo -e "${RED}[-] Missing in cloud (needs migration):${NC}"
            echo "$missing_in_cloud" | while read -r name; do
                [[ -z "$name" ]] && continue
                echo "  • $name"
            done
        fi
        
        if [[ -n "$extra_in_cloud" ]]; then
            echo -e "${YELLOW}[!] Extra in cloud (not in local):${NC}"
            echo "$extra_in_cloud" | while read -r name; do
                [[ -z "$name" ]] && continue
                echo "  • $name"
            done
        fi
    done
}

compare_spaces() {
    echo -e "\n${YELLOW}=== Analyzing Kibana Spaces ===${NC}"
    
    if [[ ! -f "$CLOUD_KB/kibana_spaces.json" || ! -f "$LOCAL_KB/kibana_spaces.json" ]]; then
        echo -e "${RED}❌ Missing kibana_spaces.json in one or both directories${NC}"
        return 1
    fi
    
    cloud_spaces=$(jq -r '.[].id' "$CLOUD_KB/kibana_spaces.json" | sort)
    local_spaces=$(jq -r '.[].id' "$LOCAL_KB/kibana_spaces.json" | sort)

    missing_in_cloud=$(comm -23 <(echo "$local_spaces") <(echo "$cloud_spaces"))
