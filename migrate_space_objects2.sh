#!/bin/bash

# Uploads filtered Kibana saved objects, splitting them into chunks.
# After the first run, it automatically creates a new file containing ONLY the objects
# that failed, so the second run can be faster and more targeted.
#
# Usage: ./migrate_space_objects.sh <filtered_export_file> [chunk_size]

# --- Configuration ---
CLOUD_KIBANA="https://kibhana_url_here.com"
DEFAULT_CHUNK_SIZE=500

# --- Colors for Output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- 1. Input and Prerequisite Checks (Omitted for brevity, same as before) ---
if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    echo -e "${RED}Usage: $0 <filtered_export_file> [chunk_size]${NC}"
    exit 1
fi
FILE="$1"
CHUNK_SIZE="${2:-$DEFAULT_CHUNK_SIZE}"
if [ ! -f "$FILE" ]; then
    echo -e "${RED}Error: File '$FILE' not found.${NC}"
    exit 1
fi
if [ -z "$CAPI_KEY" ]; then
    echo -e "${RED}Error: CAPI_KEY environment variable is not set.${NC}"
    exit 1
fi
if [[ "$FILE" =~ filtered_(.*)_export\.ndjson ]]; then
    SPACE="${BASH_REMATCH[1]}"
else
    echo -e "${RED}Error: Cannot extract space name from filename '$FILE'.${NC}"
    exit 1
fi
# --- End of Checks ---

# --- 2. Prepare for Upload ---
TOTAL_OBJECTS=$(wc -l < "$FILE" | tr -d ' ')
echo -e "${BLUE}Starting upload for space: ${YELLOW}${SPACE}${NC}"
# ... (rest of preparation output is the same)

TEMP_DIR=$(mktemp -d)
trap "rm -rf '$TEMP_DIR'" EXIT

# Create a temporary file to log the IDs of all failed objects
FAILED_IDS_LOG="$TEMP_DIR/failed_ids.log"
touch "$FAILED_IDS_LOG"

split -l "$CHUNK_SIZE" "$FILE" "$TEMP_DIR/chunk_"
CHUNK_FILES=($(ls "$TEMP_DIR"/chunk_*))
TOTAL_CHUNKS=${#CHUNK_FILES[@]}
echo "Split '$FILE' into ${TOTAL_CHUNKS} chunks."
echo ""

# --- 3. Upload Each Chunk ---
SUCCESS_COUNT=0
FAILED_COUNT=0

for i in "${!CHUNK_FILES[@]}"; do
    # ... (chunk preparation is the same as before)
    chunk_file="${CHUNK_FILES[$i]}"
    chunk_num=$((i + 1))
    chunk_file_with_ext="${chunk_file}.ndjson"
    mv "$chunk_file" "$chunk_file_with_ext"
    chunk_objects=$(wc -l < "$chunk_file_with_ext" | tr -d ' ')
    echo -e "${BLUE}Uploading chunk ${chunk_num}/${TOTAL_CHUNKS} (${chunk_objects} objects)...${NC}"
    
    response=$(curl -s -w "\nHTTP_STATUS:%{http_code}" -X POST "${CLOUD_KIBANA}/s/${SPACE}/api/saved_objects/_import?overwrite=false" \
      -H "kbn-xsrf: true" \
      -H "Authorization: ApiKey ${CAPI_KEY}" \
      --form file=@"$chunk_file_with_ext")
      
    http_status=$(echo "$response" | tail -n1 | cut -d: -f2)
    response_body=$(echo "$response" | sed '$d')

    if [ "$http_status" -eq 200 ] && echo "$response_body" | jq -e '.success' > /dev/null 2>&1; then
        echo -e "${GREEN}✓ Chunk ${chunk_num} uploaded successfully!${NC}"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        echo -e "${RED}✗ Chunk ${chunk_num} failed with HTTP Status: ${http_status}${NC}"
        echo "$response_body" | jq '.'
        FAILED_COUNT=$((FAILED_COUNT + 1))
        
        # --- NEW: Extract failed IDs and log them ---
        echo "$response_body" | jq -r '.errors[].id' >> "$FAILED_IDS_LOG"
    fi
    echo ""
    sleep 1
done

# --- 4. Final Summary and Failure Isolation ---
echo "---"
echo "Upload Summary:"
echo -e "- Total chunks: ${YELLOW}${TOTAL_CHUNKS}${NC}"
# ... (rest of summary is the same)

# --- NEW: Check if any objects failed and create a filtered file ---
if [ -s "$FAILED_IDS_LOG" ]; then
    failed_count=$(wc -l < "$FAILED_IDS_LOG" | tr -d ' ')
    FAILED_OBJECTS_FILE="failed_$(basename "$FILE")"
    
    echo -e "${YELLOW}Identified ${failed_count} specific objects that failed across all chunks.${NC}"
    echo "Creating a new file with only these failed objects (more efficiently using jq)..."

    # Step 1: Read all failed IDs from the log file into a single JSON array string.
    # `jq -R .`: Reads each line as a raw string.
    # `jq -s .`: Slurps all these strings into a single JSON array.
    JQ_FAILED_IDS=$(jq -R . "$FAILED_IDS_LOG" | jq -s .)
    
    # Step 2: Use jq to filter the original NDJSON file.
    # `--argjson failed_ids_arr "$JQ_FAILED_IDS"`: Passes the JSON array of failed IDs into jq.
    # `select(.id | IN($failed_ids_arr[]))`: For each JSON object in the input file,
    # it selects the object if its 'id' field is found within the `failed_ids_arr`.
    # `-c`: Ensures the output is compact, with each JSON object on a single line (NDJSON).
    # `2>/dev/null`: Suppresses any stderr messages from jq (e.g., if a line isn't valid JSON).
    if ! jq -c --argjson failed_ids_arr "$JQ_FAILED_IDS" 'select(.id | IN($failed_ids_arr[]))' "$FILE" > "$FAILED_OBJECTS_FILE" 2>/dev/null; then
        echo -e "${YELLOW}Warning: jq encountered an issue processing '$FILE' or building the ID list. Check file content or FAILED_IDS_LOG.${NC}"
    fi
    
    echo -e "${GREEN}✓ Successfully created '${FAILED_OBJECTS_FILE}'${NC}"
    echo -e "${BLUE}You can now re-run the migration using this smaller file to resolve the errors.${NC}"
    echo "Example: ./migrate_space_objects.sh ${FAILED_OBJECTS_FILE}"
else
    echo -e "\n${GREEN}🎉 All objects migrated successfully to the '${SPACE}' space!${NC}"
fi
# if [ -s "$FAILED_IDS_LOG" ]; then
#     failed_count=$(wc -l < "$FAILED_IDS_LOG" | tr -d ' ')
#     FAILED_OBJECTS_FILE="failed_$(basename "$FILE")"
    
#     echo -e "${YELLOW}Identified ${failed_count} specific objects that failed across all chunks.${NC}"
#     echo "Creating a new file with only these failed objects..."

#     # Use grep to efficiently find all lines in the original file that contain a failed ID
#     grep -F -f "$FAILED_IDS_LOG" "$FILE" > "$FAILED_OBJECTS_FILE"
    
#     echo -e "${GREEN}✓ Successfully created '${FAILED_OBJECTS_FILE}'${NC}"
#     echo -e "${BLUE}You can now re-run the migration using this smaller file to resolve the errors.${NC}"
#     echo "Example: ./migrate_space_objects.sh ${FAILED_OBJECTS_FILE}"
# else
#     echo -e "\n${GREEN}🎉 All objects migrated successfully to the '${SPACE}' space!${NC}"
# fi

if [ $FAILED_COUNT -ne 0 ]; then
    exit 1
fi