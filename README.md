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
