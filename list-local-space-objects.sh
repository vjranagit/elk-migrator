#!/bin/bash

# Directory where local saved objects are exported
SAVED_OBJECTS_DIR="local_saved_objects"

echo "Saved Object Categories by Space:"
echo "---------------------------------"

for file in $SAVED_OBJECTS_DIR/local_kibana_space_*_export.ndjson; do
    space=$(echo "$file" | sed 's/.*local_kibana_space_\(.*\)_export.ndjson/\1/')
    echo "Space: $space"
    # List all types and their counts
    jq -r '.type' "$file" | sort | uniq -c | sort -nr
    echo ""
done
