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

# Command line argument parsing
VERBOSE=false
EXPORT_DIR=""

while [[ $# -gt 0 ]]; do
  case $1 in
    -v|--verbose)
      VERBOSE=true
      shift
      ;;
    -e|--export)
      EXPORT_DIR="$2"
      shift
      shift
      ;;
    *)
      echo "Usage: $0 [-v|--verbose] [-e|--export <directory>]"
      echo "  -v, --verbose    Show detailed output"
      echo "  -e, --export     Export missing objects to specified directory"
      exit 1
      ;;
  esac
done

# Create export directory if specified
if [[ -n "$EXPORT_DIR" ]]; then
  mkdir -p "$EXPORT_DIR"
fi

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

# Function to export missing objects to files (complete JSON objects)
export_missing_objects() {
    local space_name="$1"
    local obj_type="$2"
    local missing_objects="$3"
    local local_file="$4"
    
    if [[ -z "$EXPORT_DIR" || -z "$missing_objects" ]]; then
        return
    fi
    
    local export_file="$EXPORT_DIR/filtered_${space_name}_export.ndjson"
    
    # Convert missing_objects (newline-separated names) to JSON array for jq
    local missing_names_json=$(echo "$missing_objects" | jq -R . | jq -s .)
    
    # Extract complete JSON objects for missing items of this type
    if [[ -f "$local_file" && -s "$local_file" ]]; then
        jq -c --argjson missing_names "$missing_names_json" --arg obj_type "$obj_type" \
            'select(.type == $obj_type) | select((.attributes.title // .id) | IN($missing_names[]))' \
            "$local_file" >> "$export_file" 2>/dev/null
    fi
    
    if [[ "$VERBOSE" == true ]]; then
        echo "  📝 Exported missing $obj_type objects to: $export_file"
    fi
}

# Function to process a single space (for parallel execution)
process_space() {
    local space_name="$1"
    local temp_dir="/tmp/kibana_analysis_$$"
    local result_file="$temp_dir/${space_name}_result.json"
    
    mkdir -p "$temp_dir"
    
    local cloud_file="$CLOUD_SAVED/cloud_kibana_space_${space_name}_export.ndjson"
    local local_file="$LOCAL_SAVED/local_kibana_space_${space_name}_export.ndjson"
    
    # Initialize result structure
    local result="{\"space\":\"$space_name\",\"status\":\"error\",\"summary\":{},\"details\":{}}"
    
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
        result="{\"space\":\"$space_name\",\"status\":\"no_objects\",\"summary\":{},\"details\":{}}"
        echo "$result" > "$result_file"
        return
    fi
    
    if [[ "$cloud_exists" == false ]]; then
        result="{\"space\":\"$space_name\",\"status\":\"no_cloud_objects\",\"summary\":{},\"details\":{}}"
        echo "$result" > "$result_file"
        return
    fi
    
    if [[ "$local_exists" == false ]]; then
        result="{\"space\":\"$space_name\",\"status\":\"no_local_objects\",\"summary\":{},\"details\":{}}"
        echo "$result" > "$result_file"
        return
    fi
    
    # Get object counts for both environments
    cloud_counts=$(count_objects_by_type "$cloud_file")
    local_counts=$(count_objects_by_type "$local_file")
    
    # Get all object types from both environments
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
        result="{\"space\":\"$space_name\",\"status\":\"no_objects\",\"summary\":{},\"details\":{}}"
        echo "$result" > "$result_file"
        return
    fi
    
    # Build summary and details
    local summary_obj="{"
    local details_obj="{"
    local first_summary=true
    local first_details=true
    
    echo "$all_types" | while read -r obj_type; do
        [[ -z "$obj_type" ]] && continue
        
        cloud_count=$(echo "$cloud_counts" | jq -r ".\"$obj_type\" // 0")
        local_count=$(echo "$local_counts" | jq -r ".\"$obj_type\" // 0")
        
        # Calculate missing (local objects not in cloud)
        local missing_count=$((local_count - cloud_count > 0 ? local_count - cloud_count : 0))
        
        # Add to summary
        if [[ "$first_summary" == true ]]; then
            first_summary=false
        else
            summary_obj="$summary_obj,"
        fi
        summary_obj="$summary_obj\"$obj_type\":{\"cloud\":$cloud_count,\"local\":$local_count,\"missing\":$missing_count}"
        
        # Get detailed object lists
        cloud_objects=$(get_objects_by_type "$cloud_file" "$obj_type")
        local_objects=$(get_objects_by_type "$local_file" "$obj_type")
        
        cloud_names=$(echo "$cloud_objects" | jq -r '.[]' | sort)
        local_names=$(echo "$local_objects" | jq -r '.[]' | sort)
        
        missing_in_cloud=$(comm -23 <(echo "$local_names") <(echo "$cloud_names"))
        extra_in_cloud=$(comm -23 <(echo "$cloud_names") <(echo "$local_names"))
        common_objects=$(comm -12 <(echo "$cloud_names") <(echo "$local_names"))
        
        # Export missing objects if requested
        if [[ -n "$missing_in_cloud" ]]; then
            export_missing_objects "$space_name" "$obj_type" "$missing_in_cloud" "$local_file"
        fi
        
        # Add to details
        if [[ "$first_details" == true ]]; then
            first_details=false
        else
            details_obj="$details_obj,"
        fi
        
        local missing_array="["
        local extra_array="["
        local common_array="["
        
        # Build arrays
        local first_item=true
        if [[ -n "$missing_in_cloud" ]]; then
            while read -r name; do
                [[ -z "$name" ]] && continue
                if [[ "$first_item" == true ]]; then
                    first_item=false
                else
                    missing_array="$missing_array,"
                fi
                name=$(echo "$name" | sed 's/"/\\"/g')
                missing_array="$missing_array\"$name\""
            done <<< "$missing_in_cloud"
        fi
        missing_array="$missing_array]"
        
        first_item=true
        if [[ -n "$extra_in_cloud" ]]; then
            while read -r name; do
                [[ -z "$name" ]] && continue
                if [[ "$first_item" == true ]]; then
                    first_item=false
                else
                    extra_array="$extra_array,"
                fi
                name=$(echo "$name" | sed 's/"/\\"/g')
                extra_array="$extra_array\"$name\""
            done <<< "$extra_in_cloud"
        fi
        extra_array="$extra_array]"
        
        first_item=true
        if [[ -n "$common_objects" ]]; then
            while read -r name; do
                [[ -z "$name" ]] && continue
                if [[ "$first_item" == true ]]; then
                    first_item=false
                else
                    common_array="$common_array,"
                fi
                name=$(echo "$name" | sed 's/"/\\"/g')
                common_array="$common_array\"$name\""
            done <<< "$common_objects"
        fi
        common_array="$common_array]"
        
        details_obj="$details_obj\"$obj_type\":{\"missing\":$missing_array,\"extra\":$extra_array,\"common\":$common_array}"
        
    done
    
    summary_obj="$summary_obj}"
    details_obj="$details_obj}"
    
    result="{\"space\":\"$space_name\",\"status\":\"processed\",\"summary\":$summary_obj,\"details\":$details_obj}"
    echo "$result" > "$result_file"
}

# Function to display results
display_results() {
    local temp_dir="/tmp/kibana_analysis_$$"
    local total_missing=0
    local spaces_with_issues=0
    
    # Summary header
    echo -e "\n${YELLOW}=== Migration Analysis Summary ===${NC}"
    
    # Process all result files
    for result_file in "$temp_dir"/*_result.json; do
        [[ ! -f "$result_file" ]] && continue
        
        local space_name=$(jq -r '.space' "$result_file")
        local status=$(jq -r '.status' "$result_file")
        local summary=$(jq -r '.summary' "$result_file")
        local details=$(jq -r '.details' "$result_file")
        
        case "$status" in
            "no_objects")
                if [[ "$VERBOSE" == true ]]; then
                    echo -e "\n${BLUE}=== Space: $space_name ===${NC}"
                    echo -e "${RED}❌ No valid objects found in either environment${NC}"
                fi
                continue
                ;;
            "no_cloud_objects")
                echo -e "\n${BLUE}=== Space: $space_name ===${NC}"
                echo -e "${RED}❌ No valid objects found in cloud environment${NC}"
                echo -e "${YELLOW}⚠ Local objects exist but need migration${NC}"
                ((spaces_with_issues++))
                continue
                ;;
            "no_local_objects")
                if [[ "$VERBOSE" == true ]]; then
                    echo -e "\n${BLUE}=== Space: $space_name ===${NC}"
                    echo -e "${RED}❌ No valid objects found in local environment${NC}"
                    echo -e "${YELLOW}⚠ Cloud objects exist (may be cloud-specific)${NC}"
                fi
                continue
                ;;
        esac
        
        # Count total missing objects for this space AND check for differences
        local space_missing=0
        local space_has_differences=false
        
        if [[ "$summary" != "{}" ]]; then
            # Calculate total missing
            space_missing=$(echo "$summary" | jq -r 'to_entries[] | .value.missing' | awk '{sum += $1} END {print sum+0}')
            
            # Check if this space has any differences (missing objects OR extra objects)
            local has_missing=$(echo "$summary" | jq -r 'to_entries[] | select(.value.missing > 0) | .key' | wc -l)
            local has_extra=$(echo "$summary" | jq -r 'to_entries[] | select(.value.cloud > .value.local) | .key' | wc -l)
            
            if [[ $has_missing -gt 0 || $has_extra -gt 0 ]]; then
                space_has_differences=true
            fi
        fi
        
        if [[ "$space_has_differences" == true ]]; then
            ((spaces_with_issues++))
        fi
        total_missing=$((total_missing + space_missing))
        
        # Display space results - show if verbose OR if there are differences
        if [[ "$VERBOSE" == true || "$space_has_differences" == true ]]; then
            echo -e "\n${BLUE}=== Space: $space_name ===${NC}"
            
            if [[ "$summary" != "{}" ]]; then
                echo -e "\n${YELLOW}Object Summary:${NC}"
                echo "$summary" | jq -r 'to_entries[] | "\(.key) \(.value.cloud) \(.value.local) \(.value.missing)"' | while read -r obj_type cloud_count local_count missing_count; do
                    local extra_count=$((cloud_count - local_count > 0 ? cloud_count - local_count : 0))
                    
                    printf "  %-20s Cloud: %3d | Local: %3d" "$obj_type" "$cloud_count" "$local_count"
                    
                    if [[ $missing_count -eq 0 && $extra_count -eq 0 && $cloud_count -gt 0 ]]; then
                        echo -e " ${GREEN}✓${NC}"
                    elif [[ $missing_count -gt 0 && $extra_count -gt 0 ]]; then
                        echo -e " ${RED}⚠ Missing: $missing_count${NC} ${YELLOW}⚠ Extra: $extra_count${NC}"
                    elif [[ $missing_count -gt 0 ]]; then
                        echo -e " ${RED}⚠ Missing: $missing_count${NC}"
                    elif [[ $extra_count -gt 0 ]]; then
                        echo -e " ${YELLOW}⚠ Extra: $extra_count${NC}"
                    else
                        echo ""
                    fi
                done
            fi
            
            # Show detailed breakdown if verbose
            if [[ "$VERBOSE" == true && "$details" != "{}" ]]; then
                echo "$details" | jq -r 'to_entries[] | "\(.key)|\(.value.missing)|\(.value.extra)|\(.value.common)"' | while IFS='|' read -r obj_type missing_json extra_json common_json; do
                    missing_list=$(echo "$missing_json" | jq -r '.[]' 2>/dev/null)
                    extra_list=$(echo "$extra_json" | jq -r '.[]' 2>/dev/null)
                    common_list=$(echo "$common_json" | jq -r '.[]' 2>/dev/null)
                    
                    echo -e "\n${YELLOW}--- $obj_type Objects ---${NC}"
                    
                    if [[ -n "$common_list" ]]; then
                        echo -e "${GREEN}[+] Already in cloud:${NC}"
                        echo "$common_list" | while read -r name; do
                            [[ -z "$name" ]] && continue
                            echo "  ✓ $name"
                        done
                    fi
                    
                    if [[ -n "$missing_list" ]]; then
                        echo -e "${RED}[-] Missing in cloud (needs migration):${NC}"
                        echo "$missing_list" | while read -r name; do
                            [[ -z "$name" ]] && continue
                            echo "  • $name"
                        done
                    fi
                    
                    if [[ -n "$extra_list" ]]; then
                        echo -e "${YELLOW}[!] Extra in cloud (not in local):${NC}"
                        echo "$extra_list" | while read -r name; do
                            [[ -z "$name" ]] && continue
                            echo "  • $name"
                        done
                    fi
                done
            fi
        fi
    done
    
    # Final summary
    echo -e "\n${YELLOW}=== Final Summary ===${NC}"
    echo -e "Total objects missing in cloud: ${RED}$total_missing${NC}"
    echo -e "Spaces with migration needs: ${RED}$spaces_with_issues${NC}"
    
    if [[ -n "$EXPORT_DIR" ]]; then
        echo -e "Missing objects exported to: ${BLUE}$EXPORT_DIR${NC}"
        echo -e "${BLUE}Files created:${NC}"
        find "$EXPORT_DIR" -name "filtered_*_export.ndjson" -type f | while read -r file; do
            local count=$(wc -l < "$file" 2>/dev/null || echo 0)
            echo -e "  • $(basename "$file"): ${count} objects"
        done
        echo -e "\n${GREEN}Usage: ./migrate_space_objects.sh <filtered_export_file> [chunk_size]${NC}"
    fi
    
    # Cleanup temp directory
    rm -rf "$temp_dir"
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
    extra_in_cloud=$(comm -23 <(echo "$cloud_spaces") <(echo "$local_spaces"))
    common_spaces=$(comm -12 <(echo "$cloud_spaces") <(echo "$local_spaces"))

    if [[ "$VERBOSE" == true ]]; then
        echo -e "\n${GREEN}[+] Spaces in both environments:${NC}"
        [ -n "$common_spaces" ] && echo "$common_spaces" || echo "  (none)"
    fi

    echo -e "\n${RED}[-] Spaces missing in cloud (needs migration):${NC}"
    [ -n "$missing_in_cloud" ] && echo "$missing_in_cloud" || echo "  (none)"

    if [[ "$VERBOSE" == true ]]; then
        echo -e "\n${YELLOW}[!] Spaces extra in cloud (not in local):${NC}"
        [ -n "$extra_in_cloud" ] && echo "$extra_in_cloud" || echo "  (none)"
    fi
}

compare_saved_objects_parallel() {
    echo -e "\n${YELLOW}=== Analyzing Kibana Saved Objects (Parallel Processing) ===${NC}"
    
    if [[ ! -d "$CLOUD_SAVED" || ! -d "$LOCAL_SAVED" ]]; then
        echo -e "${RED}❌ Missing saved objects directories in one or both environments${NC}"
        return 1
    fi
    
    # Clear export directory if it exists
    if [[ -n "$EXPORT_DIR" ]]; then
        rm -f "$EXPORT_DIR"/filtered_*_export.ndjson
    fi
    
    # Get all spaces that have saved objects in either environment
    cloud_files=($(ls "$CLOUD_SAVED"/cloud_kibana_space_*_export.ndjson 2>/dev/null | xargs -n1 basename | sort))
    local_files=($(ls "$LOCAL_SAVED"/local_kibana_space_*_export.ndjson 2>/dev/null | xargs -n1 basename | sort))

    cloud_spaces=($(printf "%s\n" "${cloud_files[@]}" | sed -E 's/cloud_kibana_space_(.*)_export.ndjson/\1/' | sort))
    local_spaces=($(printf "%s\n" "${local_files[@]}" | sed -E 's/local_kibana_space_(.*)_export.ndjson/\1/' | sort))

    # Get all unique spaces
    all_spaces=($(printf "%s\n" "${cloud_spaces[@]}" "${local_spaces[@]}" | sort -u))
    
    if [[ ${#all_spaces[@]} -eq 0 ]]; then
        echo -e "${RED}❌ No spaces found with saved objects${NC}"
        return 1
    fi
    
    echo -e "Processing ${#all_spaces[@]} spaces in parallel..."
    
    # Create temp directory for results
    local temp_dir="/tmp/kibana_analysis_$$"
    mkdir -p "$temp_dir"
    
    # Export functions and variables for parallel execution
    export -f process_space count_objects_by_type get_objects_by_type export_missing_objects
    export CLOUD_SAVED LOCAL_SAVED EXPORT_DIR VERBOSE
    
    # Process spaces in parallel
    printf "%s\n" "${all_spaces[@]}" | xargs -n1 -P20 -I {} bash -c 'process_space "{}"'
    
    # Display results
    display_results
}

# Main execution
echo -e "${YELLOW}Analyzing Kibana Spaces and Objects in: $latest_folder${NC}"
echo -e "${YELLOW}Mode: $([ "$VERBOSE" == true ] && echo "Verbose" || echo "Summary Only")${NC}"
[ -n "$EXPORT_DIR" ] && echo -e "${YELLOW}Export Directory: $EXPORT_DIR${NC}"

# Compare spaces first
compare_spaces

# Then compare objects within each space using parallel processing
compare_saved_objects_parallel

echo -e "\n${YELLOW}=== Analysis Complete ===${NC}"