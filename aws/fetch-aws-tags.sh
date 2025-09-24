#!/bin/bash

# AWS Tag Fetcher Script
# Usage: ./fetch-aws-tags <resource-id>
# Example: ./fetch-aws-tags i-1234567890abcdef0

# Configuration
AWS_PROFILE="default"  # Change this to your AWS profile name
AWS_REGION="ap-south-1"  # Change this to your preferred region

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_color() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# Function to detect resource type from ID
get_resource_type() {
    local resource_id=$1
    
    case $resource_id in
        i-*)
            echo "ec2-instance"
            ;;
        vol-*)
            echo "volume"
            ;;
        snap-*)
            echo "snapshot"
            ;;
        ami-*)
            echo "image"
            ;;
        sg-*)
            echo "security-group"
            ;;
        vpc-*)
            echo "vpc"
            ;;
        subnet-*)
            echo "subnet"
            ;;
        igw-*)
            echo "internet-gateway"
            ;;
        rtb-*)
            echo "route-table"
            ;;
        eni-*)
            echo "network-interface"
            ;;
        eip-*)
            echo "elastic-ip"
            ;;
        lb-*|arn:aws:elasticloadbalancing:*loadbalancer*)
            echo "load-balancer"
            ;;
        arn:aws:elasticloadbalancing:*listener-rule*)
            echo "listener-rule"
            ;;
        arn:aws:elasticloadbalancing:*listener*)
            echo "listener"
            ;;
        nlb-*)
            echo "network-load-balancer"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

# Function to fetch and format tags
fetch_and_format_tags() {
    local resource_id=$1
    local resource_type=$2
    
    print_color $BLUE "Fetching tags for $resource_type: $resource_id"
    
    local tags_output=""
    
    case $resource_type in
        "ec2-instance"|"volume"|"snapshot"|"image"|"security-group"|"vpc"|"subnet"|"internet-gateway"|"route-table"|"network-interface")
            tags_output=$(aws ec2 describe-tags \
                --profile "$AWS_PROFILE" \
                --region "$AWS_REGION" \
                --filters "Name=resource-id,Values=$resource_id" \
                --query 'Tags[*].[Key,Value]' \
                --output text 2>/dev/null)
            ;;
        "load-balancer"|"network-load-balancer"|"listener"|"listener-rule")
            tags_output=$(aws elbv2 describe-tags \
                --profile "$AWS_PROFILE" \
                --region "$AWS_REGION" \
                --resource-arns "$resource_id" \
                --query 'TagDescriptions[0].Tags[*].[Key,Value]' \
                --output text 2>/dev/null)
            
            # If ELBv2 fails, try classic ELB
            if [ $? -ne 0 ] || [ -z "$tags_output" ]; then
                tags_output=$(aws elb describe-tags \
                    --profile "$AWS_PROFILE" \
                    --region "$AWS_REGION" \
                    --load-balancer-names "$resource_id" \
                    --query 'TagDescriptions[0].Tags[*].[Key,Value]' \
                    --output text 2>/dev/null)
            fi
            ;;
        *)
            print_color $RED "Unknown resource type for $resource_id"
            return 1
            ;;
    esac
    
    if [ $? -ne 0 ] || [ -z "$tags_output" ]; then
        print_color $RED "✗ Failed to fetch tags for $resource_id"
        return 1
    fi
    
    print_color $GREEN "✓ Successfully fetched tags for $resource_id"
    echo ""
    
    # Format tags in the array format
    print_color $YELLOW "TAGS=("
    
    while IFS=$'\t' read -r key value; do
        if [ -n "$key" ] && [ -n "$value" ]; then
            echo "    \"Key=$key,Value=$value\""
        fi
    done <<< "$tags_output"
    
    print_color $YELLOW ")"
    echo ""
    
    # Also provide a copyable version without colors
    print_color $BLUE "=== COPYABLE FORMAT (without colors) ==="
    echo "TAGS=("
    
    while IFS=$'\t' read -r key value; do
        if [ -n "$key" ] && [ -n "$value" ]; then
            echo "    \"Key=$key,Value=$value\""
        fi
    done <<< "$tags_output"
    
    echo ")"
    
    return 0
}

# Function to display help
show_help() {
    cat << EOF
AWS Tag Fetcher Script

Usage: $0 [OPTIONS] <resource-id>

OPTIONS:
    -p, --profile PROFILE    AWS profile to use (default: $AWS_PROFILE)
    -r, --region REGION      AWS region to use (default: $AWS_REGION)
    -h, --help              Show this help message

EXAMPLES:
    $0 i-1234567890abcdef0
    $0 -p production -r us-east-1 vol-0987654321fedcba0
    
SUPPORTED RESOURCE TYPES:
    - EC2 Instances (i-*)
    - EBS Volumes (vol-*)
    - Snapshots (snap-*)
    - AMIs (ami-*)
    - Security Groups (sg-*)
    - VPCs (vpc-*)
    - Subnets (subnet-*)
    - Internet Gateways (igw-*)
    - Route Tables (rtb-*)
    - Network Interfaces (eni-*)
    - Load Balancers (arn:aws:elasticloadbalancing:* or lb-*)

EOF
}

# Parse command line arguments
RESOURCE_ID=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -p|--profile)
            AWS_PROFILE="$2"
            shift 2
            ;;
        -r|--region)
            AWS_REGION="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        -*)
            print_color $RED "Unknown option: $1"
            show_help
            exit 1
            ;;
        *)
            if [ -z "$RESOURCE_ID" ]; then
                RESOURCE_ID="$1"
            else
                print_color $RED "Error: Multiple resource IDs provided. Please provide only one."
                show_help
                exit 1
            fi
            shift
            ;;
    esac
done

# Check if resource ID was provided
if [ -z "$RESOURCE_ID" ]; then
    print_color $RED "Error: No resource ID provided"
    show_help
    exit 1
fi

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    print_color $RED "Error: AWS CLI is not installed or not in PATH"
    exit 1
fi

# Verify AWS credentials
print_color $BLUE "Checking AWS credentials for profile: $AWS_PROFILE"
aws sts get-caller-identity --profile "$AWS_PROFILE" --region "$AWS_REGION" > /dev/null

if [ $? -ne 0 ]; then
    print_color $RED "Error: AWS credentials not configured or invalid for profile: $AWS_PROFILE"
    exit 1
fi

print_color $GREEN "✓ AWS credentials verified"

# Display configuration
print_color $YELLOW "Configuration:"
echo "  AWS Profile: $AWS_PROFILE"
echo "  AWS Region: $AWS_REGION"
echo "  Resource ID: $RESOURCE_ID"
echo ""

# Detect resource type
resource_type=$(get_resource_type "$RESOURCE_ID")

if [ "$resource_type" = "unknown" ]; then
    print_color $RED "✗ Unknown resource type for $RESOURCE_ID"
    exit 1
fi

print_color $YELLOW "Detected resource type: $resource_type"
echo ""

# Fetch and format tags
if fetch_and_format_tags "$RESOURCE_ID" "$resource_type"; then
    print_color $GREEN "✓ Tags fetched successfully!"
    exit 0
else
    print_color $RED "✗ Failed to fetch tags"
    exit 1
fi