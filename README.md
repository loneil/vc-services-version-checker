# VC Services Version Checker

Automating commands I use to check out project versions/helm chart/etc for VC Services in OpenShift. 
Basically just calling `oc` CLI to fetch labels, or call some ACA-Py endpoints. 
Should never have any credentials or anything like that added to config or script, it's just relying on accessing OCP locally with your token and then running the CLI, so you must have OCP access to any projects listed in config.

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

# Optional: override the deployment name used by query| lines for a specific env
# (e.g. when a namespace uses a differently-named deployment)
query-deployment|<service>|<env>|<deployment_name>

# Query API endpoint (calls /status, extracts "version" field)
api|<service>|<env>|<secret_name>|<secret_key>|<base_url>|<display_name>
```

### Per-environment deployment overrides

`query|` lines apply the same deployment name to every environment of a service.
When a single environment uses a differently-named deployment (for example, the
traction sandbox namespace prefixes resources with `traction-sandbox-`), add a
`query-deployment|` line to override the name for that env only:

```
query|traction|traction-tenant-proxy|app.kubernetes.io/version|Release Tag
query|traction|traction-tenant-proxy|helm.sh/chart|Helm Chart
query-deployment|traction|sandbox|traction-sandbox-tenant-proxy
```

All `query|` lines for that service will use the overridden deployment name in
the specified env, and fall back to the default in all other envs.

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
