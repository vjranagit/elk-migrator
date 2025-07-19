#!/bin/bash

echo "Cloud Saved Object Categories by Space:"
echo "---------------------------------------"

find cloud_saved_objects/ -name 'cloud_kibana_space_*_export.ndjson' | \
xargs -I{} -P 10 bash -c '
    file="{}"
    space=$(echo "$file" | sed "s/.*cloud_kibana_space_\(.*\)_export.ndjson/\1/")
    jq -r ".type" "$file" | sort | uniq -c | sort -nr && echo "Space: $space"
    echo ""
'
