# VC Services Version Checker

A bash script that queries OpenShift deployments and APIs to collect version information and generate a Markdown report.

## Prerequisites

- `oc` CLI installed and in PATH
- Access to target OpenShift namespaces

## Configuration

Edit `config.cfg` using pipe-delimited format:

```
# Server
server|<openshift_api_url>

# Define a service
service|<name>|<repo_url>

# Define environments for a service
env|<service>|<env_name>|<namespace>

# Query deployment labels
query|<service>|<deployment_name>|<label>|<display_name>

# Query API endpoint (calls /status, extracts "version" field)
api|<service>|<env>|<secret_name>|<secret_key>|<base_url>|<display_name>
```

## Usage

```bash
# Run for all services
./check-versions.sh

# Run for a specific service
./check-versions.sh -s traction

# Custom config/output
./check-versions.sh -c myconfig.cfg -o output.md
```

The script will prompt for an OpenShift login token if not already authenticated.

Output is written to `report.md` and printed to stdout.
