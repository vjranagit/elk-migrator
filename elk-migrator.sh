#!/bin/bash

set -euo pipefail

CONFIG_FILE="profiles.yml"
ACTION=""
PROFILES=()
SRC_PROFILE=""
DST_PROFILE=""
OUTPUT=""
PATTERN=""
TASKS=1

usage() {
  cat <<USAGE
Unified Elasticsearch/Kibana migration helper.

Usage: $0 -a <action> [options]

Actions:
  export   Export resources for one or more profiles
  compare  Compare latest exports between two profiles
  migrate  Migrate selected resources from a source profile to a destination profile

Options:
  -p, --profile NAME   Profile to operate on (repeatable for export)
  -s, --source  NAME   Source profile (for compare/migrate)
  -d, --dest    NAME   Destination profile (for compare/migrate)
  -c, --config  FILE   YAML config with profile definitions (default: profiles.yml)
  -o, --output  NAME   Optional output file or index name
      --pattern PATTERN  Optional pattern to filter resources
      --tasks   N        Number of parallel tasks (default: 1)
  -h, --help           Show this help
USAGE
  exit 1
}

# parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    -a|--action) ACTION="$2"; shift 2;;
    -p|--profile) PROFILES+=("$2"); shift 2;;
    -s|--source) SRC_PROFILE="$2"; shift 2;;
    -d|--dest) DST_PROFILE="$2"; shift 2;;
    -c|--config) CONFIG_FILE="$2"; shift 2;;
    -o|--output) OUTPUT="$2"; shift 2;;
    --pattern) PATTERN="$2"; shift 2;;
    --tasks) TASKS="$2"; shift 2;;
    -h|--help) usage;;
    *) echo "Unknown option $1"; usage;;
  esac
done

[ -z "$ACTION" ] && usage

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
command -v yq >/dev/null 2>&1 || { echo "yq is required" >&2; exit 1; }

load_profile() {
  local profile="$1"
  ES_URL=$(yq e ".profiles.${profile}.es_url" "$CONFIG_FILE")
  KIBANA_URL=$(yq e ".profiles.${profile}.kibana_url" "$CONFIG_FILE")
  API_KEY=$(yq e ".profiles.${profile}.api_key" "$CONFIG_FILE")
  if [[ "$ES_URL" == "null" || "$KIBANA_URL" == "null" || "$API_KEY" == "null" ]]; then
    echo "Profile '$profile' not found in $CONFIG_FILE" >&2
    exit 1
  fi
}

es_request() {
  local method="$1"; shift
  local endpoint="$1"; shift
  local data="${1:-}"
  if [[ "$method" == "GET" ]]; then
    curl -s -X GET -H "Authorization: ApiKey $API_KEY" "$ES_URL/$endpoint"
  elif [[ "$method" == "PUT" ]]; then
    curl -s -X PUT -H "Authorization: ApiKey $API_KEY" -H "Content-Type: application/json" -d "$data" "$ES_URL/$endpoint"
  elif [[ "$method" == "POST" ]]; then
    curl -s -X POST -H "Authorization: ApiKey $API_KEY" -H "Content-Type: application/json" -d "$data" "$ES_URL/$endpoint"
  elif [[ "$method" == "DELETE" ]]; then
    curl -s -X DELETE -H "Authorization: ApiKey $API_KEY" "$ES_URL/$endpoint"
  else
    echo "Unsupported HTTP method: $method" >&2
    return 1
  fi
}

kibana_request() {
  local method="$1"; shift
  local endpoint="$1"; shift
  local data="${1:-}"
  if [[ "$method" == "GET" ]]; then
    curl -s -X GET "$KIBANA_URL/$endpoint" \
      -H "kbn-xsrf: true" \
      -H "Authorization: ApiKey $API_KEY" \
      -H "Content-Type: application/json"
  elif [[ "$method" == "POST" ]]; then
    curl -s -X POST "$KIBANA_URL/$endpoint" \
      -H "kbn-xsrf: true" \
      -H "Authorization: ApiKey $API_KEY" \
      -H "Content-Type: application/json" \
      -d "$data"
  else
    echo "Unsupported HTTP method: $method" >&2
    return 1
  fi
}

export_kibana_saved_objects() {
  local export_base="$1"
  local spaces=$(kibana_request GET "api/spaces/space")
  echo "$spaces" | jq '.' > "$export_base/kibana/kibana_spaces.json"
  local space_ids=$(echo "$spaces" | jq -r '.[].id')
  mkdir -p "$export_base/saved_objects"
  for space in $space_ids; do
    kibana_request POST "s/${space}/api/saved_objects/_export" '{"type":["*"],"excludeExportDetails":true,"includeReferencesDeep":true}' \
      > "$export_base/saved_objects/${space}.ndjson"
  done
}

export_profile() {
  local profile="$1"
  load_profile "$profile"
  local export_dir="$EXPORT_DIR"
  mkdir -p "$export_dir/es_resources/$profile" "$export_dir/kibana/$profile"
  es_request GET "_cluster/settings?include_defaults=false" | jq '.persistent' > "$export_dir/es_resources/$profile/cluster_settings.json"
  es_request GET "_ilm/policy" | jq '.' > "$export_dir/es_resources/$profile/ilm_policy.json"
  es_request GET "_index_template" | jq '.' > "$export_dir/es_resources/$profile/index_templates.json"
  es_request GET "_security/role" | jq '.' > "$export_dir/es_resources/$profile/security_roles.json"
  es_request GET "_snapshot" | jq '.' > "$export_dir/es_resources/$profile/snapshot_repos.json" || true
  export_kibana_saved_objects "$export_dir/kibana/$profile"
}

compare_templates() {
  local src_file="$1" dst_file="$2"
  echo "\n=== Analyzing index_templates.json ==="
  src_names=$(jq -r '.index_templates[].name' "$src_file" | sort)
  dst_names=$(jq -r '.index_templates[].name' "$dst_file" | sort)
  missing=$(comm -23 <(echo "$src_names") <(echo "$dst_names"))
  extra=$(comm -23 <(echo "$dst_names") <(echo "$src_names"))
  echo "Already in destination:"; comm -12 <(echo "$src_names") <(echo "$dst_names")
  echo "Missing in destination:"; [ -n "$missing" ] && echo "$missing" || echo "(none)"
  echo "Extra in destination:"; [ -n "$extra" ] && echo "$extra" || echo "(none)"
}

compare_profile_exports() {
  local src="$1" dst="$2"
  local latest=$(ls -td elastic_export_* | head -1)
  local src_base="$latest/es_resources/$src"
  local dst_base="$latest/es_resources/$dst"
  compare_templates "$src_base/index_templates.json" "$dst_base/index_templates.json"
}

migrate_ilm_policies() {
  local export_dir="$1"
  load_profile "$DST_PROFILE"
  local ilm_file="$export_dir/es_resources/$SRC_PROFILE/ilm_policy.json"
  local policies=$(jq -r 'keys[]' "$ilm_file")
  for pol in $policies; do
    new_name="migrated_$(date +%Y%m%d_%H%M%S)_${pol}"
    body=$(jq --arg p "$pol" '.[$p]' "$ilm_file")
    es_request PUT "_ilm/policy/$new_name" "$body" > /dev/null
    echo "Migrated $pol as $new_name"
  done
}

case "$ACTION" in
  export)
    [ ${#PROFILES[@]} -eq 0 ] && { echo "At least one -p/--profile required" >&2; exit 1; }
    EXPORT_DIR="elastic_export_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$EXPORT_DIR"
    for prof in "${PROFILES[@]}"; do
      echo "Exporting profile $prof"
      export_profile "$prof"
    done
    echo "Export completed under $EXPORT_DIR"
    ;;
  compare)
    [ -z "$SRC_PROFILE" ] && { echo "--source required" >&2; exit 1; }
    [ -z "$DST_PROFILE" ] && { echo "--dest required" >&2; exit 1; }
    compare_profile_exports "$SRC_PROFILE" "$DST_PROFILE"
    ;;
  migrate)
    [ -z "$SRC_PROFILE" ] && { echo "--source required" >&2; exit 1; }
    [ -z "$DST_PROFILE" ] && { echo "--dest required" >&2; exit 1; }
    latest=$(ls -td elastic_export_* | head -1)
    migrate_ilm_policies "$latest"
    ;;
  *)
    usage
    ;;
esac
