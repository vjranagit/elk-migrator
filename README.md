# Elasticsearch Migration Toolkit

This repository is a Bash script toolkit for exporting, comparing, and migrating configurations and saved objects between on-premise and cloud Elasticsearch/Kibana deployments.

## Codebase Overview
- `elastic-exporter.sh`: collects configs and saved objects from source and destination clusters.
- `compare.sh`: analyzes differences between exports to highlight what needs migration.
- `migrationv2.sh` (and iterative versions): migrates missing resources to the cloud by creating new prefixed objects.
- Utility scripts handle specialized tasks, e.g., `filter_space_objects.sh` for restricting exports or `migrate_space_objects2.sh` for saved objects per space.

Exports are written to timestamped directories containing subfolders for Elasticsearch configs, Kibana settings, and per-space saved objects.

## Architecture and Key Concepts
- Scripts rely on the Elasticsearch and Kibana REST APIs via `curl`.
- `jq` processes JSON payloads.
- Required environment variables store API keys and base URLs (`OAPI_KEY`, `CAPI_KEY`, `LOCAL_ES_URL`, `CLOUD_ES_URL`, `LOCAL_KIBANA`, `CLOUD_KIBANA`).
- Migration is non-destructive: new resources are created with prefixed names rather than overwriting existing cloud data.

## Getting Started
1. Install `jq` and ensure `curl` is available.
2. Set the environment variables for local and cloud endpoints and API keys.
3. Run `./elastic-exporter.sh` to capture data, `./compare.sh` to inspect differences, and `./migrationv2.sh` to migrate the missing pieces.

## Learn More
- Explore Elasticsearch and Kibana REST APIs to understand the endpoints used by the scripts.
- Learn `jq` for querying and manipulating JSON.
- Experiment with the advanced scripts (`filter_space_objects.sh`, `migrate_space_objects2.sh`, `export_security.sh`) to handle large exports or security-focused scenarios.
- Always test in a non-production environment before running in production.

## Contributing
Contributions are welcome. Please open issues or pull requests with improvements or bug fixes.

## License
This toolkit is provided as-is for educational and operational purposes. Always back up environments before running migrations.

## Export Directory Structure

Running `elastic-exporter.sh` or `elastic_export.sh` creates a timestamped directory such as `elastic_export_YYYYMMDD_HHMMSS` with a predictable layout:

```
elastic_export_<timestamp>/
├── es_resources/
│   ├── cloud/
│   │   ├── cluster_settings.json
│   │   ├── ilm_policy.json
│   │   ├── index_templates.json
│   │   ├── logstash_pipelines.json
│   │   ├── security_roles.json
│   │   └── snapshot_repos.json
│   └── local/
│       ├── cluster_settings.json
│       ├── ilm_policy.json
│       ├── index_templates.json
│       ├── logstash_pipelines.json
│       ├── security_roles.json
│       └── snapshot_repos.json
├── kibana/
│   ├── cloud/kibana_spaces.json
│   └── local/kibana_spaces.json
├── cloud_saved_objects/
│   └── cloud_kibana_space_<space>_export.ndjson
├── local_saved_objects/
│   └── local_kibana_space_<space>_export.ndjson
└── filtered_objects/ (created by filtering utilities)
```

This layout allows `compare.sh` and related utilities to diff equivalent resources across environments.

## Script Reference

### Export & Listing Utilities
- **`elastic-exporter.sh`** – Primary orchestrator that exports Elasticsearch settings, Kibana spaces, and per‑space saved objects. Includes helper subcommands for direct API calls and batch saved‑object extraction.
- **`elastic_export.sh`** – Earlier standalone export helper used by other scripts and by `export_security.sh`.
- **`list-local-space-objects.sh` / `list-cloud-space-objects.sh`** – Summaries of saved object types per space from the latest export.
- **`filter_space_objects.sh`** – Filters `local_saved_objects` to a curated set of types (dashboard, lens, visualization, etc.) and writes trimmed files under `filtered_objects/`.
- **`export_security.sh`** – Uses `stacker.yaml` profiles to export only security-related data (roles, users, API keys) for multiple deployments and generates a Markdown summary.

### Comparison Tools
- **`compare.sh`** – Diffs Elasticsearch resources, Kibana spaces, and saved objects between local and cloud exports. Highlights missing, extra, and differing entries with color‑coded output.
- **`comparev2.sh`** – Variant of `compare.sh` with similar logic; maintained for historical reference.
- **`compare_kibana_objects.sh`** – Compares saved objects across all spaces and reports counts by type.
- **`compare_kibana_object.sh`** – Enhanced single‑space analyzer; supports verbose output and optional export of missing items.

### Migration Helpers
- **`migration.sh`** – Interactive migrator that prefixes new Elasticsearch and Kibana resources with a timestamp, preserving existing cloud data. Includes functions for ILM policy and pipeline migration and for transforming saved object IDs.
- **`migrationv2.sh`** – Streamlined migration script that creates missing resources and prefixed copies of conflicts; handles version fields in ILM policies.
- **`migrationv3.sh`** – Alternate iteration with similar goals; kept for experimentation.
- **`migrate_space_objects2.sh`** – Uploads filtered NDJSON files in configurable chunks, tracks failures, and generates a retry file with only problematic object IDs.

## Architecture Notes

- **Environment Variables** – Scripts rely on `LOCAL_ES_URL`, `CLOUD_ES_URL`, `LOCAL_KIBANA`, `CLOUD_KIBANA`, `OAPI_KEY`, and `CAPI_KEY`. `export_security.sh` additionally uses `stacker.yaml` and requires `yq`.
- **Tools** – `curl` performs REST calls and `jq` (plus `yq` where applicable) manipulates JSON. Some utilities run tasks in parallel via `xargs -P` for efficiency.
- **Non‑Destructive Strategy** – Migration scripts avoid overwriting existing cloud resources. When differences are detected, new items are created with a `migrated_<timestamp>_` prefix or similar naming scheme.
- **Saved Object Handling** – Kibana exports are per‑space NDJSON files. Filtering and migration utilities operate on these files to limit types or chunk uploads.

## Learning Resources and Next Steps

1. Explore the Elasticsearch and Kibana REST API documentation to understand the endpoints used by these scripts.
2. Practice `jq` and `yq` for structured query and transformation of JSON and YAML.
3. Run a full cycle in a test environment:
   - `./elastic-exporter.sh`
   - `./compare.sh`
   - `./migrationv2.sh` or `./migration.sh`
4. Review advanced helpers (`filter_space_objects.sh`, `migrate_space_objects2.sh`, `export_security.sh`) for large or specialized migrations.
5. Inspect the generated export directories to become familiar with the data shape before applying migrations in production.
