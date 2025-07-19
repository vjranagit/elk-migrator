#!/bin/bash

# Filter Kibana saved objects to keep only required types
# Usage:
#   ./filter_objects.sh                     - Processes all 'local_kibana_space_*_export.ndjson' files in parallel.
#   ./filter_objects.sh <filename.ndjson>   - Processes only the specified file.

# Define required object types
REQUIRED_TYPES=(
    "canvas-workpad"
    "cases"
    "cases-comments"
    "cases-user-actions"
    "dashboard"
    "infrastructure-ui-source"
    "lens"
    "map"
    "metrics-data-source"
    "query"
    "search"
    "synthetics-privates-locations"
    "tag"
    "uptime-dynamic-settings"
    "visualization"
    "index-pattern"
)

# Convert array to jq filter format
# This filter will be used to select objects based on their 'type' field.
FILTER_CONDITION=""
for type in "${REQUIRED_TYPES[@]}"; do
    if [ -z "$FILTER_CONDITION" ]; then
        FILTER_CONDITION=".type == \"$type\""
    else
        FILTER_CONDITION="$FILTER_CONDITION or .type == \"$type\""
    fi
done

# Export the FILTER_CONDITION so it's available in subshells created by xargs
export FILTER_CONDITION

# Create filtered directory if it doesn't exist
mkdir -p filtered_objects

# Function to process a single NDJSON file
process_file() {
    local file="$1" # The file path passed as the first argument to the function

    if [ -f "$file" ]; then
        echo "Processing: $file"
        
        # Extract space name from filename.
        # Assumes filenames are like 'local_kibana_space_YOUR_SPACE_NAME_export.ndjson'
        # If the filename doesn't match this pattern, it will use the full filename.
        space_name=$(echo "$file" | sed -n 's/.*local_kibana_space_\(.*\)_export.ndjson/\1/p')
        if [ -z "$space_name" ]; then
            # Fallback if the pattern doesn't match, use the base filename without extension
            space_name=$(basename "$file" .ndjson)
        fi
        
        # Define the output file path for filtered objects
        filtered_file="filtered_objects/filtered_${space_name}_export.ndjson"
        
        # Clear previous content of the filtered file to ensure a clean start
        > "$filtered_file"
        
        # Filter objects using jq and append to the filtered file
        # -c: compact output, each JSON object on a single line
        # select($FILTER_CONDITION): filters objects based on the exported FILTER_CONDITION
        # 2>/dev/null: suppresses any jq errors (e.g., if a line is not valid JSON)
        if ! jq -c "select($FILTER_CONDITION)" "$file" >> "$filtered_file" 2>/dev/null; then
            echo "Warning: jq encountered an issue processing $file. Check file content for valid JSON."
        fi
        
        # Calculate and display statistics
        original_count=$(wc -l < "$file")
        filtered_count=$(wc -l < "$filtered_file" 2>/dev/null || echo 0) # Handle case where filtered_file might be empty
        
        echo "  Original: $original_count objects"
        echo "  Filtered: $filtered_count objects"
        echo "  Removed: $((original_count - filtered_count)) objects"
        echo
    else
        echo "Error: File not found: $file"
    fi
}

# Export the function so it can be called by xargs in subshells
export -f process_file

# --- Main Script Logic ---

# Check if a specific file is provided as an argument
if [ -n "$1" ]; then
    # If an argument is provided, process only that file
    echo "Processing single file: $1"
    process_file "$1"
else
    # If no argument, find all matching files and process them in parallel
    echo "Starting parallel processing of all matching files with xargs -P 10..."
    # find: locates files matching the pattern
    # -maxdepth 1: limits search to the current directory
    # -name "local_kibana_space_*_export.ndjson": matches the desired file pattern
    # -print0: prints file names separated by a null character, safe for special characters in filenames
    # xargs: executes commands on the found files
    # -0: reads null-terminated input
    # -P 10: runs up to 10 processes in parallel (adjust based on your system's capabilities)
    # -n 1: passes one argument (filename) at a time to the command
    # bash -c 'process_file "$@"' _: executes the process_file function in a new bash shell
    find . -maxdepth 1 -name "local_kibana_space_*_export.ndjson" -print0 | \
    xargs -0 -P 10 -n 1 bash -c 'process_file "$@"' _
    echo "Parallel processing complete."
fi

# --- Summary Section ---
echo "Filtered files saved to: filtered_objects/"
echo "Summary of object types in filtered files:"
echo "----------------------------------------"

# Iterate through all filtered files and show a summary of object types
for file in filtered_objects/filtered_*_export.ndjson; do
    if [ -f "$file" ]; then
        # Extract space name for display in the summary
        space=$(echo "$file" | sed -n 's/.*filtered_\(.*\)_export.ndjson/\1/p')
        if [ -z "$space" ]; then
            space=$(basename "$file" .ndjson | sed 's/^filtered_//')
        fi
        echo "Space: $space"
        # Use jq to extract the 'type' field from each JSON object, sort, count unique, and sort by count
        cat "$file" | jq -r '.type' | sort | uniq -c | sort -nr
        echo
    fi
done