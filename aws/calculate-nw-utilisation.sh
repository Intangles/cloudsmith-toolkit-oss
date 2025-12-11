#!/bin/bash

# EC2 Network Utilization Report Script
# Generates CSV output of network utilization (NetworkIn/NetworkOut) for EC2 instances
# filtered by tag, with avg (5m averaged), min, and max values over a specified time period
#
# Usage: ./calculate-nw-utilisation.sh -t <tag-key> -v <tag-value> -s <start-time> -e <end-time> [-r <region>] [-p <profile>] [-o <output-file>]
#
# Examples:
#   ./calculate-nw-utilisation.sh -t int:app@service -v ironman-rabbitmq -s "2025-12-10T18:30:00" -e "2025-12-10T19:30:00"
#   ./calculate-nw-utilisation.sh -t Name -v "web-server*" -s "2025-12-01" -e "2025-12-11" -r us-east-1 -o report.csv

set -e

# Default Configuration
AWS_PROFILE="${AWS_PROFILE:-default}"
AWS_REGION="${AWS_REGION:-ap-south-1}"
PERIOD=300  # 5 minutes in seconds
OUTPUT_FILE=""

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Function to print usage
usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Generates CSV report of EC2 network utilization filtered by tag.

Required Options:
    -t, --tag-key       Tag key to filter EC2 instances (e.g., Environment, Name, Project)
    -v, --tag-value     Tag value to filter (supports wildcards like "prod*")
    -s, --start-time    Start time in ISO 8601 format (e.g., 2025-12-01T00:00:00)
    -e, --end-time      End time in ISO 8601 format (e.g., 2025-12-10T23:59:59)

Optional:
    -r, --region        AWS region (default: ${AWS_REGION})
    -p, --profile       AWS profile (default: ${AWS_PROFILE})
    -o, --output        Output CSV file (default: stdout)
    -h, --help          Show this help message

Examples:
    $(basename "$0") -t Environment -v production -s "2025-12-01T00:00:00" -e "2025-12-10T23:59:59"
    $(basename "$0") -t Name -v "web-*" -s "2025-12-01" -e "2025-12-11" -r us-east-1 -o report.csv

Output Columns:
    - InstanceId: EC2 instance ID
    - InstanceName: Name tag of the instance
    - InstanceType: EC2 instance type
    - NetworkIn_Avg_Bytes: Average bytes received (5m averaged)
    - NetworkIn_Min_Bytes: Minimum bytes received
    - NetworkIn_Max_Bytes: Maximum bytes received
    - NetworkOut_Avg_Bytes: Average bytes sent (5m averaged)
    - NetworkOut_Min_Bytes: Minimum bytes sent
    - NetworkOut_Max_Bytes: Maximum bytes sent
    - NetworkIn_Avg_Mbps: Average ingress in Mbps
    - NetworkOut_Avg_Mbps: Average egress in Mbps

EOF
    exit 1
}

# Function to print colored messages
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" >&2
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -t|--tag-key)
                TAG_KEY="$2"
                shift 2
                ;;
            -v|--tag-value)
                TAG_VALUE="$2"
                shift 2
                ;;
            -s|--start-time)
                START_TIME="$2"
                shift 2
                ;;
            -e|--end-time)
                END_TIME="$2"
                shift 2
                ;;
            -r|--region)
                AWS_REGION="$2"
                shift 2
                ;;
            -p|--profile)
                AWS_PROFILE="$2"
                shift 2
                ;;
            -o|--output)
                OUTPUT_FILE="$2"
                shift 2
                ;;
            -h|--help)
                usage
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                ;;
        esac
    done

    # Validate required parameters
    if [[ -z "$TAG_KEY" ]]; then
        log_error "Tag key (-t) is required"
        usage
    fi
    if [[ -z "$TAG_VALUE" ]]; then
        log_error "Tag value (-v) is required"
        usage
    fi
    if [[ -z "$START_TIME" ]]; then
        log_error "Start time (-s) is required"
        usage
    fi
    if [[ -z "$END_TIME" ]]; then
        log_error "End time (-e) is required"
        usage
    fi
}

# Function to get EC2 instances by tag
get_ec2_instances_by_tag() {
    local tag_key="$1"
    local tag_value="$2"
    
    log_info "Fetching EC2 instances with tag ${tag_key}=${tag_value}..."
    
    aws ec2 describe-instances \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --filters "Name=tag:${tag_key},Values=${tag_value}" "Name=instance-state-name,Values=running,stopped" \
        --query 'Reservations[*].Instances[*].[InstanceId,InstanceType,Tags[?Key==`Name`].Value | [0]]' \
        --output json | jq -r '.[][] | @tsv'
}

# Function to get CloudWatch metrics for an instance
get_network_metrics() {
    local instance_id="$1"
    local metric_name="$2"
    local start_time="$3"
    local end_time="$4"
    
    aws cloudwatch get-metric-statistics \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --namespace AWS/EC2 \
        --metric-name "$metric_name" \
        --dimensions Name=InstanceId,Value="$instance_id" \
        --start-time "$start_time" \
        --end-time "$end_time" \
        --period "$PERIOD" \
        --statistics Average Minimum Maximum \
        --output json 2>/dev/null
}

# Function to calculate aggregated metrics from CloudWatch data
calculate_aggregated_metrics() {
    local metrics_json="$1"
    
    # Parse the datapoints and calculate overall avg, min, max
    echo "$metrics_json" | jq -r '
        if (.Datapoints | length) > 0 then
            {
                avg: (([.Datapoints[].Average] | add) / ([.Datapoints[].Average] | length)),
                min: ([.Datapoints[].Minimum] | min),
                max: ([.Datapoints[].Maximum] | max)
            } | "\(.avg)\t\(.min)\t\(.max)"
        else
            "0\t0\t0"
        end
    '
}

# Function to convert bytes to Mbps (for 5-minute period)
bytes_to_mbps() {
    local bytes="$1"
    # bytes per 5 minutes -> bits per second -> Mbps
    # (bytes * 8) / (300 seconds) / 1000000
    echo "scale=4; ($bytes * 8) / 300 / 1000000" | bc 2>/dev/null || echo "0"
}

# Main function to generate the report
generate_report() {
    local csv_header="InstanceId,InstanceName,InstanceType,NetworkIn_Avg_Bytes,NetworkIn_Min_Bytes,NetworkIn_Max_Bytes,NetworkOut_Avg_Bytes,NetworkOut_Min_Bytes,NetworkOut_Max_Bytes,NetworkIn_Avg_Mbps,NetworkOut_Avg_Mbps"
    
    # Output header
    if [[ -n "$OUTPUT_FILE" ]]; then
        echo "$csv_header" > "$OUTPUT_FILE"
    else
        echo "$csv_header"
    fi
    
    # Get instances
    local instances
    instances=$(get_ec2_instances_by_tag "$TAG_KEY" "$TAG_VALUE")
    
    if [[ -z "$instances" ]]; then
        log_warning "No EC2 instances found with tag ${TAG_KEY}=${TAG_VALUE}"
        exit 0
    fi
    
    local instance_count
    instance_count=$(echo "$instances" | wc -l | tr -d ' ')
    log_info "Found ${instance_count} EC2 instance(s)"
    
    local processed=0
    
    # Process each instance
    while IFS=$'\t' read -r instance_id instance_type instance_name; do
        ((processed++))
        log_info "Processing instance ${processed}/${instance_count}: ${instance_id} (${instance_name:-unnamed})"
        
        # Handle empty instance name
        instance_name="${instance_name:-N/A}"
        
        # Get NetworkIn metrics
        local network_in_json
        network_in_json=$(get_network_metrics "$instance_id" "NetworkIn" "$START_TIME" "$END_TIME")
        local network_in_stats
        network_in_stats=$(calculate_aggregated_metrics "$network_in_json")
        
        # Get NetworkOut metrics
        local network_out_json
        network_out_json=$(get_network_metrics "$instance_id" "NetworkOut" "$START_TIME" "$END_TIME")
        local network_out_stats
        network_out_stats=$(calculate_aggregated_metrics "$network_out_json")
        
        # Parse the stats
        local in_avg in_min in_max out_avg out_min out_max
        in_avg=$(echo "$network_in_stats" | cut -f1)
        in_min=$(echo "$network_in_stats" | cut -f2)
        in_max=$(echo "$network_in_stats" | cut -f3)
        out_avg=$(echo "$network_out_stats" | cut -f1)
        out_min=$(echo "$network_out_stats" | cut -f2)
        out_max=$(echo "$network_out_stats" | cut -f3)
        
        # Calculate Mbps for average values
        local in_avg_mbps out_avg_mbps
        in_avg_mbps=$(bytes_to_mbps "${in_avg:-0}")
        out_avg_mbps=$(bytes_to_mbps "${out_avg:-0}")
        
        # Format numbers (round to 2 decimal places)
        in_avg=$(printf "%.2f" "${in_avg:-0}" 2>/dev/null || echo "0")
        in_min=$(printf "%.2f" "${in_min:-0}" 2>/dev/null || echo "0")
        in_max=$(printf "%.2f" "${in_max:-0}" 2>/dev/null || echo "0")
        out_avg=$(printf "%.2f" "${out_avg:-0}" 2>/dev/null || echo "0")
        out_min=$(printf "%.2f" "${out_min:-0}" 2>/dev/null || echo "0")
        out_max=$(printf "%.2f" "${out_max:-0}" 2>/dev/null || echo "0")
        in_avg_mbps=$(printf "%.4f" "${in_avg_mbps:-0}" 2>/dev/null || echo "0")
        out_avg_mbps=$(printf "%.4f" "${out_avg_mbps:-0}" 2>/dev/null || echo "0")
        
        # Escape instance name for CSV (handle commas)
        instance_name="${instance_name//\"/\"\"}"
        if [[ "$instance_name" == *","* ]]; then
            instance_name="\"${instance_name}\""
        fi
        
        # Output CSV row
        local csv_row="${instance_id},${instance_name},${instance_type},${in_avg},${in_min},${in_max},${out_avg},${out_min},${out_max},${in_avg_mbps},${out_avg_mbps}"
        
        if [[ -n "$OUTPUT_FILE" ]]; then
            echo "$csv_row" >> "$OUTPUT_FILE"
        else
            echo "$csv_row"
        fi
        
    done <<< "$instances"
    
    if [[ -n "$OUTPUT_FILE" ]]; then
        log_success "Report saved to ${OUTPUT_FILE}"
    fi
    
    log_success "Processed ${processed} instance(s)"
}

# Check dependencies
check_dependencies() {
    local missing=()
    
    for cmd in aws jq bc; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing[*]}"
        log_info "Please install: brew install ${missing[*]}"
        exit 1
    fi
}

# Main execution
main() {
    check_dependencies
    parse_args "$@"
    
    log_info "AWS Profile: ${AWS_PROFILE}"
    log_info "AWS Region: ${AWS_REGION}"
    log_info "Tag Filter: ${TAG_KEY}=${TAG_VALUE}"
    log_info "Time Range: ${START_TIME} to ${END_TIME}"
    log_info "Metric Period: ${PERIOD} seconds (5 minutes)"
    
    generate_report
}

main "$@"
