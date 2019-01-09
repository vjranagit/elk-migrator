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
