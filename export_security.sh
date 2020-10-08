#!/bin/bash

# Multi-Environment Security Export Script
# This script exports only security configurations from multiple Elasticsearch deployments
# using the existing elastic_export.sh script and stacker.yaml configuration

set -e

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ELASTIC_EXPORT_SCRIPT="${SCRIPT_DIR}/elastic_export.sh"
STACKER_CONFIG="${SCRIPT_DIR}/stacker/stacker.yaml"
EXPORT_BASE_DIR="security_export_$(date +%Y%m%d_%H%M%S)"

# Check if required files exist
if [[ ! -f "$ELASTIC_EXPORT_SCRIPT" ]]; then
    echo "Error: elastic_export.sh not found at $ELASTIC_EXPORT_SCRIPT"
    exit 1
fi

if [[ ! -f "$STACKER_CONFIG" ]]; then
    echo "Error: stacker.yaml not found at $STACKER_CONFIG"
    exit 1
fi

# Check if required tools are available
for cmd in yq jq; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: $cmd is required but not installed"
        exit 1
    fi
done

# Function to setup environment variables for a specific profile
setup_env_for_profile() {
    local profile=$1
    
    # Extract configuration from stacker.yaml
    local es_url=$(yq eval ".profiles.${profile}.elasticsearch.base_url" "$STACKER_CONFIG")
    local kibana_url=$(yq eval ".profiles.${profile}.kibana.base_url" "$STACKER_CONFIG")
    local auth_header=$(yq eval ".profiles.${profile}.client.headers.Authorization" "$STACKER_CONFIG")
    
    # Check if profile exists
    if [[ "$es_url" == "null" || "$kibana_url" == "null" || "$auth_header" == "null" ]]; then
        echo "Error: Profile '$profile' not found or incomplete in stacker.yaml"
        return 1
    fi
    
    # Extract API key from Authorization header
    local api_key=$(echo "$auth_header" | sed 's/^ApiKey //')
    
    # Set environment variables that elastic_export.sh expects
    if [[ "$profile" == "cloud" ]]; then
        export CLOUD_ES_URL="$es_url"
        export CLOUD_KIBANA="$kibana_url"
        export CAPI_KEY="$api_key"
    else
        # For all other profiles, treat as "local" environment
        export LOCAL_ES_URL="$es_url"
        export LOCAL_KIBANA="$kibana_url"
        export OAPI_KEY="$api_key"
    fi
}

# Function to export security configurations for a single profile
export_security_for_profile() {
    local profile=$1
    local env_type=$2  # "local" or "cloud"
    local profile_dir="${SCRIPT_DIR}/${EXPORT_BASE_DIR}/${profile}"
    local security_dir="${profile_dir}/security"
    
    echo "=== Exporting security configurations for profile: $profile ==="
    
    # Create directory structure first and verify it exists
    echo "Creating directory structure: $security_dir"
    if ! mkdir -p "$security_dir"; then
        echo "Error: Failed to create directory structure: $security_dir"
        return 1
    fi
    
    # Verify directory exists
    if [[ ! -d "$security_dir" ]]; then
        echo "Error: Security directory does not exist after creation: $security_dir"
        return 1
    fi
    
    echo "✓ Directory structure created successfully"
    
    # Setup environment for this profile
    setup_env_for_profile "$profile"
    
    echo "Exporting security roles..."
    if "$ELASTIC_EXPORT_SCRIPT" es "$env_type" GET "_security/role" > "$security_dir/roles.json" 2>/dev/null; then
        echo "✓ Successfully exported roles"
    else
        echo "Warning: Failed to export roles for $profile"
        # Ensure directory exists before writing fallback
        mkdir -p "$security_dir"
        echo "{}" > "$security_dir/roles.json"
    fi
    
    echo "Exporting security role mappings..."
    if "$ELASTIC_EXPORT_SCRIPT" es "$env_type" GET "_security/role_mapping" > "$security_dir/role_mappings.json" 2>/dev/null; then
        echo "✓ Successfully exported role mappings"
    else
        echo "Warning: Failed to export role mappings for $profile"
        # Ensure directory exists before writing fallback
        mkdir -p "$security_dir"
        echo "{}" > "$security_dir/role_mappings.json"
    fi
    
    echo "Exporting security users..."
    if "$ELASTIC_EXPORT_SCRIPT" es "$env_type" GET "_security/user" > "$security_dir/users.json" 2>/dev/null; then
        echo "✓ Successfully exported users"
    else
        echo "Warning: Failed to export users for $profile"
        # Ensure directory exists before writing fallback
        mkdir -p "$security_dir"
        echo "{}" > "$security_dir/users.json"
    fi
    
    echo "Exporting API keys..."
    if "$ELASTIC_EXPORT_SCRIPT" es "$env_type" GET "_security/api_key" > "$security_dir/api_keys.json" 2>/dev/null; then
        echo "✓ Successfully exported API keys"
    else
        echo "Warning: Failed to export API keys for $profile"
        # Ensure directory exists before writing fallback
        mkdir -p "$security_dir"
        echo "{}" > "$security_dir/api_keys.json"
    fi
    
    echo "Exporting security privileges..."
    if "$ELASTIC_EXPORT_SCRIPT" es "$env_type" GET "_security/privilege" > "$security_dir/privileges.json" 2>/dev/null; then
        echo "✓ Successfully exported privileges"
    else
        echo "Warning: Failed to export privileges for $profile"
        # Ensure directory exists before writing fallback
        mkdir -p "$security_dir"
        echo "{}" > "$security_dir/privileges.json"
    fi
    
    echo "Exporting application privileges..."
    if "$ELASTIC_EXPORT_SCRIPT" es "$env_type" GET "_security/privilege/_all" > "$security_dir/application_privileges.json" 2>/dev/null; then
        echo "✓ Successfully exported application privileges"
    else
        echo "Warning: Failed to export application privileges for $profile"
        # Ensure directory exists before writing fallback
        mkdir -p "$security_dir"
        echo "{}" > "$security_dir/application_privileges.json"
    fi
    
    # Export additional security-related configurations
    echo "Exporting service tokens..."
    if "$ELASTIC_EXPORT_SCRIPT" es "$env_type" GET "_security/service" > "$security_dir/service_tokens.json" 2>/dev/null; then
        echo "✓ Successfully exported service tokens"
    else
        echo "Warning: Failed to export service tokens for $profile"
        # Ensure directory exists before writing fallback
        mkdir -p "$security_dir"
        echo "{}" > "$security_dir/service_tokens.json"
    fi
    
    echo "✓ Completed security export for profile: $profile"
    echo ""
}
# Function to create a summary report
create_summary_report() {
    local summary_file="${SCRIPT_DIR}/${EXPORT_BASE_DIR}/EXPORT_SUMMARY.md"
    
    echo "# Security Export Summary" > "$summary_file"
    echo "Export Date: $(date)" >> "$summary_file"
    echo "" >> "$summary_file"
    
    # List all profiles exported
    echo "## Exported Profiles" >> "$summary_file"
    for profile_dir in "${SCRIPT_DIR}/${EXPORT_BASE_DIR}"/*; do
        if [[ -d "$profile_dir" && "$(basename "$profile_dir")" != "scripts" ]]; then
            local profile=$(basename "$profile_dir")
            echo "- **$profile**" >> "$summary_file"
            
            # Count exported items
            local roles_count=$(jq -r 'keys | length' "$profile_dir/security/roles.json" 2>/dev/null || echo "0")
            local users_count=$(jq -r 'keys | length' "$profile_dir/security/users.json" 2>/dev/null || echo "0")
            local mappings_count=$(jq -r 'keys | length' "$profile_dir/security/role_mappings.json" 2>/dev/null || echo "0")
            local api_keys_count=$(jq -r '.api_keys | length' "$profile_dir/security/api_keys.json" 2>/dev/null || echo "0")
            
            echo "  - Roles: $roles_count" >> "$summary_file"
            echo "  - Users: $users_count" >> "$summary_file"
            echo "  - Role Mappings: $mappings_count" >> "$summary_file"
            echo "  - API Keys: $api_keys_count" >> "$summary_file"
            echo "" >> "$summary_file"
        fi
    done
    
    echo "## File Structure" >> "$summary_file"
    echo '```' >> "$summary_file"
    tree "${SCRIPT_DIR}/${EXPORT_BASE_DIR}" >> "$summary_file" 2>/dev/null || find "${SCRIPT_DIR}/${EXPORT_BASE_DIR}" -type f | sort >> "$summary_file"
    echo '```' >> "$summary_file"
    
