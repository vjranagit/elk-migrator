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
    
    echo "## Security Items Exported" >> "$summary_file"
    echo "" >> "$summary_file"
    echo "For each profile, the following security configurations are exported:" >> "$summary_file"
    echo "" >> "$summary_file"
    echo "- **roles.json** - Security roles and their permissions" >> "$summary_file"
    echo "- **users.json** - User accounts and their properties" >> "$summary_file"
    echo "- **role_mappings.json** - Role mappings for external authentication" >> "$summary_file"
    echo "- **api_keys.json** - API keys and their metadata" >> "$summary_file"
    echo "- **privileges.json** - Custom application privileges" >> "$summary_file"
    echo "- **application_privileges.json** - Application-specific privileges" >> "$summary_file"
    echo "- **service_tokens.json** - Service account tokens" >> "$summary_file"
}

# Main execution function
main() {
    echo "Starting multi-environment security export..."
    echo "Export directory: $EXPORT_BASE_DIR"
    echo ""
    
    # Create base export directory with absolute path
    mkdir -p "${SCRIPT_DIR}/${EXPORT_BASE_DIR}"
    
    # Get all profiles from stacker.yaml
    profiles=$(yq eval '.profiles | keys | .[]' "$STACKER_CONFIG")
    
    # Export security configurations for each profile
    for profile in $profiles; do
        # Determine environment type (cloud vs local)
        local env_type="local"
        if [[ "$profile" == "cloud" ]]; then
            env_type="cloud"
        fi
        
        export_security_for_profile "$profile" "$env_type"
    done
    
    # Create summary report
    echo "Creating summary report..."
    create_summary_report
    
    echo "=================================================="
    echo "Security export completed successfully!"
    echo "Export location: ${SCRIPT_DIR}/${EXPORT_BASE_DIR}"
    echo "Summary report: ${SCRIPT_DIR}/${EXPORT_BASE_DIR}/EXPORT_SUMMARY.md"
    echo "=================================================="
}

# Show help
show_help() {
    echo "Multi-Environment Security Export Script"
    echo ""
    echo "This script exports security configurations from all Elasticsearch deployments"
    echo "defined in your stacker.yaml configuration file."
    echo ""
    echo "Usage:"
    echo "  $0                    - Export from all profiles"
    echo "  $0 <profile>          - Export from specific profile only"
    echo "  $0 help               - Show this help message"
    echo ""
    echo "Requirements:"
    echo "  - elastic_export.sh script in the same directory"
    echo "  - stacker/stacker.yaml configuration file"
    echo "  - yq and jq tools installed"
    echo ""
    echo "Security Items Exported:"
    echo "  - Security roles and permissions"
    echo "  - User accounts"
    echo "  - Role mappings"
    echo "  - API keys"
    echo "  - Application privileges"
    echo "  - Service tokens"
    echo ""
    echo "Output:"
    echo "  - Creates timestamped export directory"
    echo "  - Exports security configurations as JSON files"
    echo "  - Creates summary report"
}

# Handle command line arguments
if [[ $# -eq 0 ]]; then
    main
elif [[ $# -eq 1 ]]; then
    case "$1" in
        "help"|"-h"|"--help")
            show_help
            ;;
        *)
            # Export specific profile
            profile=$1
            # Check if profile exists in stacker.yaml
            if ! yq eval ".profiles.${profile}" "$STACKER_CONFIG" | grep -q -v "null"; then
                echo "Error: Profile '$profile' not found in stacker.yaml"
                echo "Available profiles:"
                yq eval '.profiles | keys | .[]' "$STACKER_CONFIG"
                exit 1
            fi
            
            echo "Exporting security configurations for profile: $profile"
            mkdir -p "${SCRIPT_DIR}/${EXPORT_BASE_DIR}"
            
            env_type="local"
            if [[ "$profile" == "cloud" ]]; then
                env_type="cloud"
            fi
            
            export_security_for_profile "$profile" "$env_type"
            create_summary_report
            
            echo "=================================================="
            echo "Security export completed successfully!"
            echo "Export location: ${SCRIPT_DIR}/${EXPORT_BASE_DIR}"
            echo "Summary report: ${SCRIPT_DIR}/${EXPORT_BASE_DIR}/EXPORT_SUMMARY.md"
            echo "=================================================="
            ;;
    esac
else
    echo "Error: Too many arguments"
    show_help
    exit 1
fi