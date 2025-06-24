# Elasticsearch and Kibana Export Script

A comprehensive bash script to export configurations and saved objects from both local and cloud Elasticsearch/Kibana environments.

## Prerequisites

- `jq` installed
- Environment variables set:
  - `$OAPI_KEY` - On-premises API key
  - `$CAPI_KEY` - Cloud API key
  - `$LOCAL_ES_URL` - Local Elasticsearch URL
  - `$CLOUD_ES_URL` - Cloud Elasticsearch URL
  - `$LOCAL_KIBANA` - Local Kibana URL
  - `$CLOUD_KIBANA` - Cloud Kibana URL

## Usage

### Full Export
```bash
./script.sh
```
Exports all resources from both environments to timestamped directory.

### Direct API Calls
```bash
# Elasticsearch API
./script.sh es <env> <method> <endpoint> [data]

# Kibana API  
./script.sh kb <env> <method> <endpoint> [data]

# Export saved objects only
./script.sh saved-objects <env>
```

### Examples
```bash
./script.sh es local GET _cluster/health
./script.sh kb cloud GET api/spaces/space
./script.sh saved-objects local
```

## What Gets Exported

**Elasticsearch:**
- Cluster settings
- ILM policies
- Index templates
- Security roles
- Snapshot repositories
- Logstash pipelines

**Kibana:**
- Spaces configuration
- Saved objects from all spaces (dashboards, visualizations, etc.)

## Output Structure
```
elastic_export_YYYYMMDD_HHMMSS/
├── es_resources/
│   ├── local/
│   └── cloud/
├── kibana/
│   ├── local/
│   └── cloud/
├── local_saved_objects/
└── cloud_saved_objects/
```

## Help
```bash
./script.sh help
```
