#!/bin/bash

# Script to find volumes by EC2 instance tags
# Usage: ./find-volumes-by-ec2-tag.sh [OPTIONS]
# 
# Options:
#   -t, --tag-key KEY        Tag key to filter by (required)
#   -v, --tag-value VALUE    Tag value to filter by (required)
#   -r, --region REGION      AWS region (default: current region)
#   -o, --output FORMAT      Output format: table, json, csv (default: table)
#   -h, --help              Show this help message
#
# Examples:
#   ./find-volumes-by-ec2-tag.sh -t Environment -v Production
#   ./find-volumes-by-ec2-tag.sh -t Name -v "Web Server" -r us-east-1
#   ./find-volumes-by-ec2-tag.sh -t Project -v MyApp -o csv
# 
# Command to extract instance IDs, volume IDs, and ENI IDs from a CSV file:
# awk -F',' 'NR>1 {print $1 "\n" $6 "\n" $11}' to_tag.csv | sort -u | tr '\n' ' ' && echo

set -euo pipefail

# Default values
TAG_KEY=""
TAG_VALUE=""
REGION=""
OUTPUT_FORMAT="table"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to display help
show_help() {
    cat << EOF
Script to find volumes by EC2 instance tags

Usage: $0 [OPTIONS]

Options:
    -t, --tag-key KEY        Tag key to filter by (required)
    -v, --tag-value VALUE    Tag value to filter by (required)
    -r, --region REGION      AWS region (default: current region)
    -o, --output FORMAT      Output format: table, json, csv (default: table)
    -h, --help              Show this help message

Examples:
    $0 -t Environment -v Production
    $0 -t Name -v "Web Server" -r us-east-1
    $0 -t Project -v MyApp -o csv

Note: Requires AWS CLI to be installed and configured with appropriate permissions.
EOF
}

# Function to log messages
log() {
    echo -e "${BLUE}[INFO]${NC} $1" >&2
}

# Function to log errors
error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Function to log warnings
warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

# Function to check if AWS CLI is installed
check_aws_cli() {
    if ! command -v aws &> /dev/null; then
        error "AWS CLI is not installed. Please install it first."
        exit 1
    fi
}

# Function to check AWS credentials
check_aws_credentials() {
    if ! aws sts get-caller-identity &> /dev/null; then
        error "AWS credentials not configured or invalid. Please run 'aws configure'."
        exit 1
    fi
}

# Function to get current AWS region
get_current_region() {
    aws configure get region || echo "us-east-1"
}

# Function to find instances by tag
find_instances_by_tag() {
    local tag_key="$1"
    local tag_value="$2"
    local region="$3"
    
    log "Searching for EC2 instances with tag ${tag_key}=${tag_value} in region ${region}..."
    
    aws ec2 describe-instances \
        --region "$region" \
        --filters "Name=tag:${tag_key},Values=${tag_value}" "Name=instance-state-name,Values=running,stopped" \
        --query 'Reservations[].Instances[].[InstanceId,InstanceType,State.Name,Tags[?Key==`Name`].Value|[0]]' \
        --output text
}

# Function to get volumes for an instance
get_instance_volumes() {
    local instance_id="$1"
    local region="$2"
    
    aws ec2 describe-instances \
        --region "$region" \
        --instance-ids "$instance_id" \
        --query 'Reservations[].Instances[].BlockDeviceMappings[].[DeviceName,Ebs.VolumeId]' \
        --output text
}

# Function to get volume details
get_volume_details() {
    local volume_id="$1"
    local region="$2"
    
    aws ec2 describe-volumes \
        --region "$region" \
        --volume-ids "$volume_id" \
        --query 'Volumes[].[VolumeId,Size,VolumeType,State,Encrypted]' \
        --output text
}

# Function to get network interfaces for an instance
get_instance_network_interfaces() {
    local instance_id="$1"
    local region="$2"
    
    aws ec2 describe-instances \
        --region "$region" \
        --instance-ids "$instance_id" \
        --query 'Reservations[].Instances[].NetworkInterfaces[].[NetworkInterfaceId,PrivateIpAddress,SubnetId,Status]' \
        --output text
}

# Function to output results in table format
output_table() {
    echo -e "\n${GREEN}EC2 Instances, their Volumes and Network Interfaces${NC}"
    echo "======================================================================================================================================================"
    printf "%-20s %-15s %-15s %-20s %-15s %-12s %-8s %-10s %-10s %-20s %-15s %-15s\n" \
        "Instance ID" "Instance Type" "Instance State" "Instance Name" "Device Name" "Volume ID" "Size (GB)" "Type" "Encrypted" "Network Interface" "Private IP" "Status"
    echo "======================================================================================================================================================"
    
    while IFS=$'\t' read -r instance_id instance_type instance_state instance_name device_name volume_id size volume_type state encrypted network_interface private_ip ni_status; do
        # Handle empty instance name
        if [[ -z "$instance_name" || "$instance_name" == "None" ]]; then
            instance_name="N/A"
        fi
        
        printf "%-20s %-15s %-15s %-20s %-15s %-12s %-8s %-10s %-10s %-20s %-15s %-15s\n" \
            "$instance_id" "$instance_type" "$instance_state" "$instance_name" \
            "$device_name" "$volume_id" "$size" "$volume_type" "$encrypted" \
            "$network_interface" "$private_ip" "$ni_status"
    done
}

# Function to output results in CSV format
output_csv() {
    echo "Instance ID,Instance Type,Instance State,Instance Name,Device Name,Volume ID,Size (GB),Volume Type,Volume State,Encrypted,Network Interface,Private IP,NI Status"
    
    while IFS=$'\t' read -r instance_id instance_type instance_state instance_name device_name volume_id size volume_type state encrypted network_interface private_ip ni_status; do
        # Handle empty instance name
        if [[ -z "$instance_name" || "$instance_name" == "None" ]]; then
            instance_name="N/A"
        fi
        
        echo "$instance_id,$instance_type,$instance_state,\"$instance_name\",$device_name,$volume_id,$size,$volume_type,$state,$encrypted,$network_interface,$private_ip,$ni_status"
    done
}

# Function to output results in JSON format
output_json() {
    echo "["
    local first=true
    
    while IFS=$'\t' read -r instance_id instance_type instance_state instance_name device_name volume_id size volume_type state encrypted network_interface private_ip ni_status; do
        # Handle empty instance name
        if [[ -z "$instance_name" || "$instance_name" == "None" ]]; then
            instance_name="N/A"
        fi
        
        if [[ "$first" == "true" ]]; then
            first=false
        else
            echo ","
        fi
        
        cat << EOF
  {
    "instanceId": "$instance_id",
    "instanceType": "$instance_type",
    "instanceState": "$instance_state",
    "instanceName": "$instance_name",
    "deviceName": "$device_name",
    "volumeId": "$volume_id",
    "sizeGB": $size,
    "volumeType": "$volume_type",
    "volumeState": "$state",
    "encrypted": $encrypted,
    "networkInterface": "$network_interface",
    "privateIp": "$private_ip",
    "niStatus": "$ni_status"
  }
EOF
    done
    
    echo -e "\n]"
}

# Main function
main() {
    local temp_file=$(mktemp)
    trap "rm -f $temp_file" EXIT
    
    # Find instances by tag
    local instances
    instances=$(find_instances_by_tag "$TAG_KEY" "$TAG_VALUE" "$REGION")
    
    if [[ -z "$instances" ]]; then
        warn "No instances found with tag ${TAG_KEY}=${TAG_VALUE} in region ${REGION}"
        exit 0
    fi
    
    log "Found instances. Getting volume information..."
    
    # Process each instance
    while IFS=$'\t' read -r instance_id instance_type instance_state instance_name; do
        if [[ -n "$instance_id" ]]; then
            log "Processing instance: $instance_id"
            
            # Get volumes for this instance
            local volumes
            volumes=$(get_instance_volumes "$instance_id" "$REGION")
            
            # Get network interfaces for this instance
            local network_interfaces
            network_interfaces=$(get_instance_network_interfaces "$instance_id" "$REGION")
            
            if [[ -n "$volumes" ]]; then
                while IFS=$'\t' read -r device_name volume_id; do
                    if [[ -n "$volume_id" ]]; then
                        # Get volume details
                        local volume_details
                        volume_details=$(get_volume_details "$volume_id" "$REGION")
                        
                        if [[ -n "$volume_details" ]]; then
                            while IFS=$'\t' read -r vol_id size volume_type vol_state encrypted; do
                                # If there are network interfaces, create an entry for each
                                if [[ -n "$network_interfaces" ]]; then
                                    while IFS=$'\t' read -r ni_id private_ip subnet_id ni_status; do
                                        if [[ -n "$ni_id" ]]; then
                                            echo -e "$instance_id\t$instance_type\t$instance_state\t$instance_name\t$device_name\t$vol_id\t$size\t$volume_type\t$vol_state\t$encrypted\t$ni_id\t$private_ip\t$ni_status" >> "$temp_file"
                                        fi
                                    done <<< "$network_interfaces"
                                else
                                    # No network interfaces, add N/A entries
                                    echo -e "$instance_id\t$instance_type\t$instance_state\t$instance_name\t$device_name\t$vol_id\t$size\t$volume_type\t$vol_state\t$encrypted\tN/A\tN/A\tN/A" >> "$temp_file"
                                fi
                            done <<< "$volume_details"
                        fi
                    fi
                done <<< "$volumes"
            else
                warn "No volumes found for instance $instance_id"
                # Still show network interfaces even if no volumes
                if [[ -n "$network_interfaces" ]]; then
                    while IFS=$'\t' read -r ni_id private_ip subnet_id ni_status; do
                        if [[ -n "$ni_id" ]]; then
                            echo -e "$instance_id\t$instance_type\t$instance_state\t$instance_name\tN/A\tN/A\tN/A\tN/A\tN/A\tN/A\t$ni_id\t$private_ip\t$ni_status" >> "$temp_file"
                        fi
                    done <<< "$network_interfaces"
                fi
            fi
        fi
    done <<< "$instances"
    
    # Output results
    if [[ -s "$temp_file" ]]; then
        case "$OUTPUT_FORMAT" in
            "table")
                output_table < "$temp_file"
                ;;
            "csv")
                output_csv < "$temp_file"
                ;;
            "json")
                output_json < "$temp_file"
                ;;
            *)
                error "Invalid output format: $OUTPUT_FORMAT"
                exit 1
                ;;
        esac
        
        # Summary
        local total_volumes
        total_volumes=$(wc -l < "$temp_file")
        local total_size
        total_size=$(awk -F'\t' '{sum += $7} END {print sum}' "$temp_file")
        
        echo -e "\n${GREEN}Summary:${NC}"
        echo "Total volumes: $total_volumes"
        echo "Total size: ${total_size} GB"
    else
        warn "No volumes found for the specified criteria"
    fi
}

# Parse command line arguments
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
        -r|--region)
            REGION="$2"
            shift 2
            ;;
        -o|--output)
            OUTPUT_FORMAT="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Validate required parameters
if [[ -z "$TAG_KEY" ]]; then
    error "Tag key is required. Use -t or --tag-key option."
    show_help
    exit 1
fi

if [[ -z "$TAG_VALUE" ]]; then
    error "Tag value is required. Use -v or --tag-value option."
    show_help
    exit 1
fi

# Set default region if not provided
if [[ -z "$REGION" ]]; then
    REGION=$(get_current_region)
    log "Using region: $REGION"
fi

# Validate output format
case "$OUTPUT_FORMAT" in
    "table"|"csv"|"json")
        ;;
    *)
        error "Invalid output format: $OUTPUT_FORMAT. Supported formats: table, csv, json"
        exit 1
        ;;
esac

# Check prerequisites
check_aws_cli
check_aws_credentials

# Run main function
main