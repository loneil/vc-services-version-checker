#!/bin/bash

# ============================================================================
# OpenShift Version Checker
# Queries deployment labels across namespaces and generates a Markdown report
# ============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Defaults
CONFIG_FILE="config.cfg"
OUTPUT_FILE="report.md"
SERVICE_FILTER=""

# Arrays to hold parsed config
declare -a SERVICES
declare -A SERVICE_REPO
declare -A SERVICE_ENVS
declare -A ENV_NS
declare -A SERVICE_QUERIES
declare -A API_QUERIES
declare -A NS_ACCESS
declare -A RESULTS
declare -A DEPLOYMENT_OVERRIDE

SERVER_URL=""

# ============================================================================
# Helper Functions
# ============================================================================

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[!]${NC} $1"
}

usage() {
    echo "Usage: $0 [-c config_file] [-o output_file] [-s service_name]"
    echo "  -c    Config file (default: config.cfg)"
    echo "  -o    Output file (default: report.md)"
    echo "  -s    Only run for specified service (e.g., -s traction)"
    exit 1
}

# ============================================================================
# Prerequisites Check
# ============================================================================

check_prerequisites() {
    if ! command -v oc &> /dev/null; then
        print_error "The 'oc' command is not installed or not in PATH"
        echo "Please install the OpenShift CLI: https://docs.openshift.com/container-platform/latest/cli_reference/openshift_cli/getting-started-cli.html"
        exit 1
    fi
    print_success "oc command found"
}

# ============================================================================
# Config Parsing
# ============================================================================

parse_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_error "Config file not found: $CONFIG_FILE"
        exit 1
    fi

    local line_num=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((++line_num))
        
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        
        # Parse pipe-delimited fields
        IFS='|' read -ra FIELDS <<< "$line"
        local type="${FIELDS[0]}"
        
        case "$type" in
            server)
                SERVER_URL="${FIELDS[1]}"
                ;;
            service)
                local name="${FIELDS[1]}"
                local repo="${FIELDS[2]}"
                SERVICES+=("$name")
                SERVICE_REPO["$name"]="$repo"
                SERVICE_ENVS["$name"]=""
                SERVICE_QUERIES["$name"]=""
                ;;
            env)
                local service="${FIELDS[1]}"
                local env_name="${FIELDS[2]}"
                local namespace="${FIELDS[3]}"
                if [[ -n "${SERVICE_ENVS[$service]}" ]]; then
                    SERVICE_ENVS["$service"]+=" $env_name"
                else
                    SERVICE_ENVS["$service"]="$env_name"
                fi
                ENV_NS["$service:$env_name"]="$namespace"
                ;;
            query)
                local service="${FIELDS[1]}"
                local deployment="${FIELDS[2]}"
                local label="${FIELDS[3]}"
                local display="${FIELDS[4]}"
                local query_line="$deployment|$label|$display"
                if [[ -n "${SERVICE_QUERIES[$service]}" ]]; then
                    SERVICE_QUERIES["$service"]+=$'\n'"$query_line"
                else
                    SERVICE_QUERIES["$service"]="$query_line"
                fi
                ;;
            query-deployment)
                # query-deployment|<service>|<env>|<deployment_name>
                # Overrides the deployment name used by query| lines for this service+env.
                local service="${FIELDS[1]}"
                local env_name="${FIELDS[2]}"
                local deployment_name="${FIELDS[3]}"
                DEPLOYMENT_OVERRIDE["$service:$env_name"]="$deployment_name"
                ;;
            api)
                # api|<service>|<env>|<secret_name>|<secret_key>|<url>|<display_name>
                local service="${FIELDS[1]}"
                local env_name="${FIELDS[2]}"
                local secret_name="${FIELDS[3]}"
                local secret_key="${FIELDS[4]}"
                local api_url="${FIELDS[5]}"
                local display="${FIELDS[6]}"
                local api_line="$secret_name|$secret_key|$api_url|$display"
                local api_key="$service:$env_name"
                if [[ -n "${API_QUERIES[$api_key]}" ]]; then
                    API_QUERIES["$api_key"]+=$'\n'"$api_line"
                else
                    API_QUERIES["$api_key"]="$api_line"
                fi
                ;;
            *)
                print_warn "Unknown config line type '$type' at line $line_num"
                ;;
        esac
    done < "$CONFIG_FILE"
    
    # Validate
    if [[ -z "$SERVER_URL" ]]; then
        print_error "No server URL defined in config. Add: server|<url>"
        exit 1
    fi
    
    if [[ ${#SERVICES[@]} -eq 0 ]]; then
        print_error "No services defined in config"
        exit 1
    fi
    
    print_success "Parsed config: ${#SERVICES[@]} services"
}

# ============================================================================
# OpenShift Login
# ============================================================================

oc_login() {
    echo ""
    print_info "OpenShift Login"
    echo "Server: $SERVER_URL"
    
    # Check if already logged in
    local current_user
    if current_user=$(oc whoami 2>/dev/null); then
        print_success "Already logged in as: $current_user"
        return 0
    fi
    
    echo ""
    echo "To get your token, visit:"
    echo "  ${SERVER_URL/api./oauth-openshift.apps.}/oauth/token/display"
    echo ""
    read -rsp "Enter your OpenShift login token: " OC_TOKEN
    echo ""
    
    if [[ -z "$OC_TOKEN" ]]; then
        print_error "No token provided"
        exit 1
    fi
    
    print_info "Logging in to OpenShift..."
    if ! oc login --token="$OC_TOKEN" --server="$SERVER_URL" --insecure-skip-tls-verify=true &> /dev/null; then
        print_error "Login failed. Please check your token."
        exit 1
    fi
    
    local user
    user=$(oc whoami 2>/dev/null)
    print_success "Logged in as: $user"
}

# ============================================================================
# Namespace Access Check
# ============================================================================

check_namespace_access() {
    print_info "Checking namespace access..."
    
    # Collect unique namespaces
    declare -A unique_ns
    for service in "${SERVICES[@]}"; do
        for env in ${SERVICE_ENVS[$service]}; do
            local ns="${ENV_NS[$service:$env]}"
            unique_ns["$ns"]=1
        done
    done
    
    local success=0
    local failed=0
    
    for ns in "${!unique_ns[@]}"; do
        if oc get namespace "$ns" &> /dev/null; then
            NS_ACCESS["$ns"]="yes"
            print_success "Access to $ns"
            ((++success)) || true
        else
            NS_ACCESS["$ns"]="no"
            print_warn "No access to $ns"
            ((++failed)) || true
        fi
    done
    
    echo ""
    print_info "Namespace access: $success accessible, $failed inaccessible"
}

# ============================================================================
# Query Execution
# ============================================================================

get_label_value() {
    local ns="$1"
    local deployment="$2"
    local label="$3"
    
    # Escape dots and slashes for jsonpath
    local escaped_label
    escaped_label=$(echo "$label" | sed "s/\./\\\./g" | sed "s/\//\\\\\//g")
    
    local jsonpath="{.metadata.labels['$escaped_label']}"
    
    local result
    result=$(oc get deployment "$deployment" -n "$ns" -o jsonpath="$jsonpath" 2>/dev/null) || result=""
    
    if [[ -z "$result" ]]; then
        echo "NOT FOUND"
    else
        echo "$result"
    fi
}
get_api_value() {
    local ns="$1"
    local secret_name="$2"
    local secret_key="$3"
    local api_url="$4"
    
    # Get the secret value (base64 decode)
    local api_key
    api_key=$(oc get secret "$secret_name" -n "$ns" -o jsonpath="{.data.$secret_key}" 2>/dev/null | base64 -d 2>/dev/null) || api_key=""
    
    if [[ -z "$api_key" ]]; then
        echo "SECRET NOT FOUND"
        return
    fi
    
    # Make the API call to /status endpoint
    local response
    local http_code
    
    # Use curl with timeout, get both body and http code
    response=$(curl -s -w "\n%{http_code}" --max-time 10 \
        -H "X-API-KEY: $api_key" \
        "${api_url}/status" 2>/dev/null) || {
        echo "API CALL FAILED"
        return
    }
    
    # Split response and http code
    http_code=$(echo "$response" | tail -n1)
    local body
    body=$(echo "$response" | sed '$d')
    
    # Check HTTP status
    if [[ "$http_code" != "200" ]]; then
        echo "HTTP $http_code"
        return
    fi
    
    # Extract version field from JSON response
    local version
    if command -v jq &> /dev/null; then
        version=$(echo "$body" | jq -r '.version // empty' 2>/dev/null)
    else
        # Fallback: basic grep/sed extraction
        version=$(echo "$body" | grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/' 2>/dev/null)
    fi
    
    if [[ -z "$version" || "$version" == "null" ]]; then
        echo "NO VERSION FIELD"
    else
        echo "$version"
    fi
}
run_queries() {
    print_info "Querying deployments..."
    echo ""
    
    local total_queries=0
    local successful_queries=0
    
    for service in "${SERVICES[@]}"; do
        print_info "Checking $service..."
        
        # Process label queries
        local query_index=0
        while IFS= read -r query_line; do
            [[ -z "$query_line" ]] && continue
            
            IFS='|' read -r deployment label display <<< "$query_line"
            
            for env in ${SERVICE_ENVS[$service]}; do
                local ns="${ENV_NS[$service:$env]}"
                local result_key="$service:$env:$query_index"
                local effective_deployment="${DEPLOYMENT_OVERRIDE[$service:$env]:-$deployment}"

                ((++total_queries)) || true

                if [[ "${NS_ACCESS[$ns]}" != "yes" ]]; then
                    RESULTS["$result_key"]="NO ACCESS"
                else
                    local value
                    value=$(get_label_value "$ns" "$effective_deployment" "$label")
                    RESULTS["$result_key"]="$value"
                    if [[ "$value" != "NOT FOUND" ]]; then
                        ((++successful_queries)) || true
                    fi
                fi
            done
            
            ((++query_index)) || true
        done <<< "${SERVICE_QUERIES[$service]}"
        
        # Process API queries (per environment)
        for env in ${SERVICE_ENVS[$service]}; do
            local ns="${ENV_NS[$service:$env]}"
            local api_key="$service:$env"
            
            [[ -z "${API_QUERIES[$api_key]}" ]] && continue
            
            while IFS= read -r api_line; do
                [[ -z "$api_line" ]] && continue
                
                IFS='|' read -r secret_name secret_key api_url display <<< "$api_line"
                local result_key="$service:$env:api:$display"
                
                ((++total_queries)) || true
                
                if [[ "${NS_ACCESS[$ns]}" != "yes" ]]; then
                    RESULTS["$result_key"]="NO ACCESS"
                else
                    print_info "  Calling API for $service/$env..."
                    local value
                    value=$(get_api_value "$ns" "$secret_name" "$secret_key" "$api_url")
                    RESULTS["$result_key"]="$value"
                    if [[ "$value" != "SECRET NOT FOUND" && "$value" != "API CALL FAILED" && ! "$value" =~ ^HTTP && "$value" != "NO VERSION FIELD" ]]; then
                        ((++successful_queries)) || true
                    fi
                fi
            done <<< "${API_QUERIES[$api_key]}"
        done
    done
    
    echo ""
    print_info "Queries complete: $successful_queries/$total_queries successful"
}

# ============================================================================
# Report Generation
# ============================================================================

generate_report() {
    print_info "Generating report: $OUTPUT_FILE"
    
    local report=""
    report+="# VC Services Environment Versions\n\n"
    report+="Generated: $(date '+%Y-%m-%d %H:%M:%S')\n\n"
    
    for service in "${SERVICES[@]}"; do
        report+="## ${service^}\n\n"  # Capitalize first letter
        
        local repo="${SERVICE_REPO[$service]}"
        if [[ -n "$repo" ]]; then
            report+="Repo: $repo\n\n"
        fi
        
        # Build header row
        local header="| |"
        local separator="|---|"
        for env in ${SERVICE_ENVS[$service]}; do
            header+=" ${env^} |"
            separator+="---|"
        done
        report+="$header\n"
        report+="$separator\n"
        
        # Add namespace row
        local ns_row="| Namespace |"
        for env in ${SERVICE_ENVS[$service]}; do
            local ns="${ENV_NS[$service:$env]}"
            ns_row+=" $ns |"
        done
        report+="$ns_row\n"
        
        # Build data rows from label queries
        local query_index=0
        while IFS= read -r query_line; do
            [[ -z "$query_line" ]] && continue
            
            IFS='|' read -r deployment label display <<< "$query_line"
            
            local row="| $display |"
            for env in ${SERVICE_ENVS[$service]}; do
                local result_key="$service:$env:$query_index"
                local value="${RESULTS[$result_key]:-N/A}"
                row+=" $value |"
            done
            report+="$row\n"
            
            ((++query_index)) || true
        done <<< "${SERVICE_QUERIES[$service]}"
        
        # Build data rows from API queries
        # First collect all unique display names across all envs
        declare -A api_displays
        for env in ${SERVICE_ENVS[$service]}; do
            local api_key="$service:$env"
            [[ -z "${API_QUERIES[$api_key]}" ]] && continue
            
            while IFS= read -r api_line; do
                [[ -z "$api_line" ]] && continue
                IFS='|' read -r secret_name secret_key api_url display <<< "$api_line"
                api_displays["$display"]=1
            done <<< "${API_QUERIES[$api_key]}"
        done
        
        # Now create rows for each unique display
        for display in "${!api_displays[@]}"; do
            local row="| $display |"
            for env in ${SERVICE_ENVS[$service]}; do
                local result_key="$service:$env:api:$display"
                local value="${RESULTS[$result_key]:-N/A}"
                row+=" $value |"
            done
            report+="$row\n"
        done
        unset api_displays
        
        report+="\n"
    done
    
    # Write to file
    echo -e "$report" > "$OUTPUT_FILE"
    
    # Also print to stdout
    echo ""
    echo "=========================================="
    echo -e "$report"
    echo "=========================================="
    
    print_success "Report saved to $OUTPUT_FILE"
}

# ============================================================================
# Main
# ============================================================================

main() {
    echo ""
    echo "======================================"
    echo "  OpenShift Version Checker"
    echo "======================================"
    echo ""
    
    # Parse CLI args
    while getopts "c:o:s:h" opt; do
        case $opt in
            c) CONFIG_FILE="$OPTARG" ;;
            o) OUTPUT_FILE="$OPTARG" ;;
            s) SERVICE_FILTER="$OPTARG" ;;
            h) usage ;;
            *) usage ;;
        esac
    done
    
    check_prerequisites
    parse_config
    
    # Filter services if -s was provided
    if [[ -n "$SERVICE_FILTER" ]]; then
        local found=false
        for svc in "${SERVICES[@]}"; do
            if [[ "$svc" == "$SERVICE_FILTER" ]]; then
                found=true
                break
            fi
        done
        if [[ "$found" != "true" ]]; then
            print_error "Service '$SERVICE_FILTER' not found in config"
            echo "Available services: ${SERVICES[*]}"
            exit 1
        fi
        SERVICES=("$SERVICE_FILTER")
        print_info "Filtering to service: $SERVICE_FILTER"
    fi
    oc_login
    check_namespace_access
    run_queries
    generate_report
    
    echo ""
    print_success "Done!"
}

main "$@"
