# Elasticsearch Migration Toolkit

A comprehensive set of bash scripts to export, compare, and migrate configurations and saved objects between Elasticsearch/Kibana environments (on-premises to cloud).

## Scripts Overview

- **`elastic-exporter.sh`** - Exports configurations and saved objects from both local and cloud environments
- **`compare.sh`** - Compares exported configurations between environments
- **`migrationv.sh`** - Migrates resources by creating new objects (non-destructive approach)

## Prerequisites

- `jq` installed on your system
- `curl` for API requests
- Environment variables configured (see setup below)

## Environment Variables Setup

Set the following environment variables in your shell:

```bash
# API Keys
export OAPI_KEY="your_on_premises_api_key"
export CAPI_KEY="your_cloud_api_key"

# Elasticsearch URLs
export LOCAL_ES_URL="https://your-local-elasticsearch:9200"
export CLOUD_ES_URL="https://your-cloud-elasticsearch:9200"

# Kibana URLs  
export LOCAL_KIBANA="https://your-local-kibana:5601"
export CLOUD_KIBANA="https://your-cloud-kibana:5601"
```

## Quick Start

1. **Export configurations from both environments:**
   ```bash
   ./elastic-exporter.sh
   ```

2. **Compare the exported configurations:**
   ```bash
   ./compare.sh
   ```

3. **Migrate resources to cloud (creates new objects):**
   ```bash
   ./migrationv.sh all
   ```

## Detailed Usage

### elastic-exporter.sh

**Full Export (Recommended):**
```bash
./elastic-exporter.sh
```
Exports all resources from both environments to a timestamped directory.

**Direct API Calls:**
```bash
# Elasticsearch API calls
./elastic-exporter.sh es <env> <method> <endpoint> [data]

# Kibana API calls
./elastic-exporter.sh kb <env> <method> <endpoint> [data]

# Export saved objects only
./elastic-exporter.sh saved-objects <env>
```

**Examples:**
```bash
./elastic-exporter.sh es local GET _cluster/health
./elastic-exporter.sh kb cloud GET api/spaces/space
./elastic-exporter.sh saved-objects local
./elastic-exporter.sh help
```

### compare.sh

**Basic Usage:**
```bash
./compare.sh
```
Automatically finds the latest export folder and compares all resources.

**Specify Export Directory:**
```bash
./compare.sh dir ./elastic_export_20250624_143022
```

### migrationv.sh

**Migrate All Resources:**
```bash
./migrationv.sh all
```

**Migrate Specific Resource Types:**
```bash
./migrationv.sh ilm                    # ILM policies
./migrationv.sh pipelines              # Logstash pipelines  
./migrationv.sh templates              # Index templates
./migrationv.sh roles                  # Security roles
./migrationv.sh spaces                 # Kibana spaces
./migrationv.sh objects                # Saved objects
./migrationv.sh settings               # Cluster settings (selective)
```

**Specify Export Directory:**
```bash
./migrationv.sh dir ./elastic_export_20250624_143022 ilm
```

**Multiple Resource Types:**
```bash
./migrationv.sh spaces objects templates
```

## What Gets Exported

### Elasticsearch Resources:
- **Cluster settings** - Persistent and transient cluster configurations
- **ILM policies** - Index Lifecycle Management policies
- **Index templates** - Index and component templates
- **Security roles** - Role-based access control definitions
- **Snapshot repositories** - Backup repository configurations
- **Logstash pipelines** - Central pipeline management configurations

### Kibana Resources:
- **Spaces configuration** - Kibana space definitions
- **Saved objects** - Dashboards, visualizations, index patterns, searches, etc.
  - Exported per space for granular control
  - Includes all object types and dependencies

## Export Directory Structure

```
elastic_export_YYYYMMDD_HHMMSS/
├── es_resources/
│   ├── local/
│   │   ├── cluster_settings.json
│   │   ├── ilm_policy.json
│   │   ├── index_templates.json
│   │   ├── security_roles.json
│   │   ├── snapshot_repositories.json
│   │   └── logstash_pipelines.json
│   └── cloud/
│       └── [same structure as local/]
├── kibana/
│   ├── local/
│   │   └── kibana_spaces.json
│   └── cloud/
│       └── kibana_spaces.json
├── local_saved_objects/
│   ├── local_kibana_space_default_export.ndjson
│   └── local_kibana_space_[space_name]_export.ndjson
└── cloud_saved_objects/
    ├── cloud_kibana_space_default_export.ndjson
    └── cloud_kibana_space_[space_name]_export.ndjson
```

## Comparison Features

The `compare.sh` script provides detailed analysis:

- **✅ Green:** Resources exist in both environments
- **❌ Red:** Resources missing in cloud (need migration)  
- **⚠️ Yellow:** Resources only in cloud (not in local)
- **Detailed diffs** for complex resources like templates and pipelines
- **Per-space comparison** for Kibana saved objects
- **Object count summaries** for each space

## Migration Strategy

The `migrationv.sh` script uses a **non-destructive approach**:

### New Object Creation
- Creates new objects with prefixed names: `migrated_YYYYMMDD_HHMMSS_[original_name]`
- Preserves existing cloud resources
- Allows safe rollback if needed
- Updates references between objects automatically

### Migration Process
1. **Analysis Phase:** Compares local vs cloud resources
2. **Planning Phase:** Shows what will be created/modified
3. **Confirmation:** Requires user approval before changes
4. **Execution Phase:** Creates new resources with updated names
5. **Verification:** Confirms successful creation

### Selective Migration
- Choose specific resource types to migrate
- Interactive cluster settings selection (safety feature)
- Skip built-in/system resources automatically
- Handle missing dependencies gracefully

## Safety Features

### Built-in Resource Protection
- Automatically skips system resources (e.g., `.monitoring-*`, `kibana_system`)
- Warns about potentially dangerous cluster settings
- Requires explicit confirmation for destructive operations

### Error Handling
- Validates API connectivity before operations
- Provides detailed error messages with suggestions
- Graceful handling of missing resources or permissions
- Rollback capabilities for failed migrations

### Verification
- Success/failure detection for all operations
- Post-creation verification by fetching created resources
- Detailed logging of all operations

## Troubleshooting

### Common Issues

**API Key Authentication:**
```bash
# Test your API keys
curl -H "Authorization: ApiKey $CAPI_KEY" "$CLOUD_ES_URL/_cluster/health"
```

**Missing Dependencies:**
```bash
# Install jq on Ubuntu/Debian
sudo apt-get install jq

# Install jq on macOS
brew install jq
```

**Permission Issues:**
```bash
# Make scripts executable
chmod +x elastic-exporter.sh compare.sh migrationv.sh
```

### Debug Mode
Add `set -x` to the beginning of any script for detailed execution logging.

## Best Practices

### Before Migration
1. **Test in non-production** environment first
2. **Backup your cloud environment** 
3. **Review comparison results** carefully
4. **Start with less critical resources** (e.g., spaces before objects)

### During Migration
1. **Migrate incrementally** - one resource type at a time
2. **Verify each step** before proceeding
3. **Keep export timestamps** for reference
4. **Document any custom modifications** needed

### After Migration
1. **Test migrated objects** functionality
2. **Update references** in applications if needed
3. **Monitor performance** impact
4. **Clean up unused resources** when confident

## Advanced Usage

### Custom Filtering
Modify the scripts to add custom filtering logic for your specific use case.

### Batch Operations
Use the individual migration functions for automated batch processing.

### Integration with CI/CD
Scripts can be integrated into deployment pipelines for consistent environment management.

## Contributing

Feel free to submit issues, feature requests, or pull requests to improve these scripts.

## License

This toolkit is provided as-is for educational and operational purposes. Use at your own risk and always test in non-production environments first.

---

**⚠️ Important:** Always backup your environments before running migration scripts. Test thoroughly in non-production environments first.
