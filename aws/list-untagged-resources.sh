#!/bin/bash

# AWS Untagged Resources Finder Script
# Usage: ./list-untagged-resources [OPTIONS]
# Example: ./list-untagged-resources --tag service --value elk-logging

# Configuration
AWS_PROFILE="default"  # Change this to your AWS profile name
AWS_REGION="ap-south-1"  # Change this to your preferred region

# Default tag to check for
DEFAULT_TAG_KEY="service"
DEFAULT_TAG_VALUE=""  # Empty means any value is acceptable

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Function to print colored output
print_color() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# Function to output resource information based on format
output_resource() {
    local resource_id=$1
    local resource_type=$2
    local state=$3
    local details=$4
    local name=$5
    
    case $OUTPUT_FORMAT in
        csv)
            # Escape commas in fields and quote if necessary
            local csv_name=$(echo "${name:-N/A}" | sed 's/,/;/g')
            local csv_details=$(echo "$details" | sed 's/,/;/g')
            echo "$resource_id,$resource_type,$state,$csv_details,$csv_name"
            ;;
        json)
            # JSON output (can be implemented later if needed)
            echo "{\"resourceId\":\"$resource_id\",\"type\":\"$resource_type\",\"state\":\"$state\",\"details\":\"$details\",\"name\":\"${name:-N/A}\"}"
            ;;
        table|*)
            printf "%-20s %-15s %-12s %-15s %s\n" "$resource_id" "$resource_type" "$state" "$details" "${name:-N/A}"
            ;;
    esac
}

# Function to check if resource has the required tag
has_required_tag() {
    local tags_json=$1
    local required_key=$2
    local required_value=$3
    
    if [ -z "$tags_json" ] || [ "$tags_json" = "null" ] || [ "$tags_json" = "[]" ]; then
        return 1  # No tags at all
    fi
    
    # Check if the required tag key exists
    local tag_exists=$(echo "$tags_json" | jq -r --arg key "$required_key" '.[] | select(.Key == $key) | .Value' 2>/dev/null)
    
    if [ -z "$tag_exists" ] || [ "$tag_exists" = "null" ]; then
        return 1  # Tag key doesn't exist
    fi
    
    # If specific value is required, check for it
    if [ -n "$required_value" ]; then
        if [ "$tag_exists" != "$required_value" ]; then
            return 1  # Tag exists but value doesn't match
        fi
    fi
    
    return 0  # Tag exists (and matches value if specified)
}

# Function to find untagged EC2 instances
check_ec2_instances() {
    local tag_key=$1
    local tag_value=$2
    local found_untagged=false
    
    if [ "$OUTPUT_FORMAT" != "csv" ]; then
        print_color $BLUE "Checking EC2 Instances..."
    fi
    
    local instances=$(aws ec2 describe-instances \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --query 'Reservations[].Instances[].[InstanceId,State.Name,InstanceType,Tags,join(`,`, [Tags[?Key==`Name`].Value] | [0])]' \
        --output json 2>/dev/null)
    
    if [ $? -eq 0 ] && [ "$instances" != "[]" ]; then
        echo "$instances" | jq -r '.[] | @base64' | while IFS= read -r encoded_instance; do
            local instance_data=$(echo "$encoded_instance" | base64 --decode)
            local instance_id=$(echo "$instance_data" | jq -r '.[0]')
            local state=$(echo "$instance_data" | jq -r '.[1]')
            local instance_type=$(echo "$instance_data" | jq -r '.[2]')
            local tags=$(echo "$instance_data" | jq -r '.[3]')
            local name=$(echo "$instance_data" | jq -r '.[4]')
            
            if ! has_required_tag "$tags" "$tag_key" "$tag_value"; then
                output_resource "$instance_id" "ec2-instance" "$state" "$instance_type" "$name"
                found_untagged=true
            fi
        done
    fi
    
    return $([ "$found_untagged" = true ] && echo 0 || echo 1)
}

# Function to find untagged EBS volumes
check_ebs_volumes() {
    local tag_key=$1
    local tag_value=$2
    local found_untagged=false
    
    print_color $BLUE "Checking EBS Volumes..."
    
    local volumes=$(aws ec2 describe-volumes \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --query 'Volumes[].[VolumeId,State,VolumeType,Size,Tags,join(`,`, [Tags[?Key==`Name`].Value] | [0])]' \
        --output json 2>/dev/null)
    
    if [ $? -eq 0 ] && [ "$volumes" != "[]" ]; then
        echo "$volumes" | jq -r '.[] | @base64' | while IFS= read -r encoded_volume; do
            local volume_data=$(echo "$encoded_volume" | base64 --decode)
            local volume_id=$(echo "$volume_data" | jq -r '.[0]')
            local state=$(echo "$volume_data" | jq -r '.[1]')
            local volume_type=$(echo "$volume_data" | jq -r '.[2]')
            local size=$(echo "$volume_data" | jq -r '.[3]')
            local tags=$(echo "$volume_data" | jq -r '.[4]')
            local name=$(echo "$volume_data" | jq -r '.[5]')
            
            if ! has_required_tag "$tags" "$tag_key" "$tag_value"; then
                output_resource "$volume_id" "ebs-volume" "$state" "${volume_type}(${size}GB)" "$name"
                found_untagged=true
            fi
        done
    fi
    
    return $([ "$found_untagged" = true ] && echo 0 || echo 1)
}

# Function to find untagged Security Groups
check_security_groups() {
    local tag_key=$1
    local tag_value=$2
    local found_untagged=false
    
    print_color $BLUE "Checking Security Groups..."
    
    local security_groups=$(aws ec2 describe-security-groups \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --query 'SecurityGroups[].[GroupId,GroupName,VpcId,Tags]' \
        --output json 2>/dev/null)
    
    if [ $? -eq 0 ] && [ "$security_groups" != "[]" ]; then
        echo "$security_groups" | jq -r '.[] | @base64' | while IFS= read -r encoded_sg; do
            local sg_data=$(echo "$encoded_sg" | base64 --decode)
            local group_id=$(echo "$sg_data" | jq -r '.[0]')
            local group_name=$(echo "$sg_data" | jq -r '.[1]')
            local vpc_id=$(echo "$sg_data" | jq -r '.[2]')
            local tags=$(echo "$sg_data" | jq -r '.[3]')
            
            if ! has_required_tag "$tags" "$tag_key" "$tag_value"; then
                output_resource "$group_id" "security-group" "active" "$vpc_id" "$group_name"
                found_untagged=true
            fi
        done
    fi
    
    return $([ "$found_untagged" = true ] && echo 0 || echo 1)
}

# Function to find untagged VPCs
check_vpcs() {
    local tag_key=$1
    local tag_value=$2
    local found_untagged=false
    
    print_color $BLUE "Checking VPCs..."
    
    local vpcs=$(aws ec2 describe-vpcs \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --query 'Vpcs[].[VpcId,State,CidrBlock,IsDefault,Tags,join(`,`, [Tags[?Key==`Name`].Value] | [0])]' \
        --output json 2>/dev/null)
    
    if [ $? -eq 0 ] && [ "$vpcs" != "[]" ]; then
        echo "$vpcs" | jq -r '.[] | @base64' | while IFS= read -r encoded_vpc; do
            local vpc_data=$(echo "$encoded_vpc" | base64 --decode)
            local vpc_id=$(echo "$vpc_data" | jq -r '.[0]')
            local state=$(echo "$vpc_data" | jq -r '.[1]')
            local cidr=$(echo "$vpc_data" | jq -r '.[2]')
            local is_default=$(echo "$vpc_data" | jq -r '.[3]')
            local tags=$(echo "$vpc_data" | jq -r '.[4]')
            local name=$(echo "$vpc_data" | jq -r '.[5]')
            
            if ! has_required_tag "$tags" "$tag_key" "$tag_value"; then
                local vpc_type=$([ "$is_default" = "true" ] && echo "default" || echo "custom")
                output_resource "$vpc_id" "vpc" "$state" "${vpc_type}($cidr)" "$name"
                found_untagged=true
            fi
        done
    fi
    
    return $([ "$found_untagged" = true ] && echo 0 || echo 1)
}

# Function to find untagged Subnets
check_subnets() {
    local tag_key=$1
    local tag_value=$2
    local found_untagged=false
    
    print_color $BLUE "Checking Subnets..."
    
    local subnets=$(aws ec2 describe-subnets \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --query 'Subnets[].[SubnetId,State,VpcId,AvailabilityZone,CidrBlock,Tags,join(`,`, [Tags[?Key==`Name`].Value] | [0])]' \
        --output json 2>/dev/null)
    
    if [ $? -eq 0 ] && [ "$subnets" != "[]" ]; then
        echo "$subnets" | jq -r '.[] | @base64' | while IFS= read -r encoded_subnet; do
            local subnet_data=$(echo "$encoded_subnet" | base64 --decode)
            local subnet_id=$(echo "$subnet_data" | jq -r '.[0]')
            local state=$(echo "$subnet_data" | jq -r '.[1]')
            local vpc_id=$(echo "$subnet_data" | jq -r '.[2]')
            local az=$(echo "$subnet_data" | jq -r '.[3]')
            local cidr=$(echo "$subnet_data" | jq -r '.[4]')
            local tags=$(echo "$subnet_data" | jq -r '.[5]')
            local name=$(echo "$subnet_data" | jq -r '.[6]')
            
            if ! has_required_tag "$tags" "$tag_key" "$tag_value"; then
                output_resource "$subnet_id" "subnet" "$state" "$az($cidr)" "$name"
                found_untagged=true
            fi
        done
    fi
    
    return $([ "$found_untagged" = true ] && echo 0 || echo 1)
}

# Function to find untagged Load Balancers (ALB/NLB)
check_load_balancers() {
    local tag_key=$1
    local tag_value=$2
    local found_untagged=false
    
    print_color $BLUE "Checking Load Balancers..."
    
    # Check ALB/NLB
    local load_balancers=$(aws elbv2 describe-load-balancers \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --query 'LoadBalancers[].[LoadBalancerArn,LoadBalancerName,Type,State.Code,VpcId]' \
        --output json 2>/dev/null)
    
    if [ $? -eq 0 ] && [ "$load_balancers" != "[]" ]; then
        echo "$load_balancers" | jq -r '.[] | @base64' | while IFS= read -r encoded_lb; do
            local lb_data=$(echo "$encoded_lb" | base64 --decode)
            local lb_arn=$(echo "$lb_data" | jq -r '.[0]')
            local lb_name=$(echo "$lb_data" | jq -r '.[1]')
            local lb_type=$(echo "$lb_data" | jq -r '.[2]')
            local state=$(echo "$lb_data" | jq -r '.[3]')
            local vpc_id=$(echo "$lb_data" | jq -r '.[4]')
            
            # Get tags for this load balancer
            local tags=$(aws elbv2 describe-tags \
                --profile "$AWS_PROFILE" \
                --region "$AWS_REGION" \
                --resource-arns "$lb_arn" \
                --query 'TagDescriptions[0].Tags' \
                --output json 2>/dev/null)
            
            if ! has_required_tag "$tags" "$tag_key" "$tag_value"; then
                local lb_id=$(echo "$lb_arn" | sed 's/.*\///')
                output_resource "$lb_id" "load-balancer" "$state" "$lb_type" "$lb_name"
                found_untagged=true
            fi
        done
    fi
    
    return $([ "$found_untagged" = true ] && echo 0 || echo 1)
}

# Function to find untagged S3 buckets
check_s3_buckets() {
    local tag_key=$1
    local tag_value=$2
    local found_untagged=false
    
    if [ "$OUTPUT_FORMAT" != "csv" ]; then
        print_color $BLUE "Checking S3 Buckets..."
    fi
    
    # Get all S3 buckets
    local buckets=$(aws s3api list-buckets \
        --profile "$AWS_PROFILE" \
        --query 'Buckets[].[Name,CreationDate]' \
        --output json 2>/dev/null)
    
    if [ $? -eq 0 ] && [ "$buckets" != "[]" ]; then
        echo "$buckets" | jq -r '.[] | @base64' | while IFS= read -r encoded_bucket; do
            local bucket_data=$(echo "$encoded_bucket" | base64 --decode)
            local bucket_name=$(echo "$bucket_data" | jq -r '.[0]')
            local creation_date=$(echo "$bucket_data" | jq -r '.[1]')
            
            # Get bucket location (region)
            local bucket_region=$(aws s3api get-bucket-location \
                --profile "$AWS_PROFILE" \
                --bucket "$bucket_name" \
                --query 'LocationConstraint' \
                --output text 2>/dev/null)
            
            # Handle default region (us-east-1 returns None/null)
            if [ "$bucket_region" = "None" ] || [ "$bucket_region" = "null" ]; then
                bucket_region="us-east-1"
            fi
            
            # Skip buckets not in the specified region (if region filtering is desired)
            # Note: S3 is global, but buckets have regions. You might want to check all buckets
            # regardless of region, or add a flag to control this behavior
            
            # Get tags for this bucket
            local tags=$(aws s3api get-bucket-tagging \
                --profile "$AWS_PROFILE" \
                --bucket "$bucket_name" \
                --query 'TagSet' \
                --output json 2>/dev/null)
            
            # Handle case where bucket has no tags (command fails)
            if [ $? -ne 0 ]; then
                tags="[]"
            fi
            
            if ! has_required_tag "$tags" "$tag_key" "$tag_value"; then
                local bucket_details="${bucket_region}"
                output_resource "$bucket_name" "s3-bucket" "active" "$bucket_details" "$bucket_name"
                found_untagged=true
            fi
        done
    fi
    
    return $([ "$found_untagged" = true ] && echo 0 || echo 1)
}

# Function to display help
show_help() {
    cat << EOF
AWS Untagged Resources Finder Script

Usage: $0 [OPTIONS]

OPTIONS:
    -t, --tag TAG_KEY       Tag key to check for (default: $DEFAULT_TAG_KEY)
    -v, --value TAG_VALUE   Specific tag value to check for (optional)
    -p, --profile PROFILE   AWS profile to use (default: $AWS_PROFILE)
    -r, --region REGION     AWS region to use (default: $AWS_REGION)
    -o, --output FORMAT     Output format: table|csv|json (default: table)
    --resources TYPES       Comma-separated list of resource types to check
                           Available: ec2,ebs,sg,vpc,subnet,elb,s3 (default: all)
    -h, --help             Show this help message

EXAMPLES:
    $0                                          # Check for missing 'service' tag
    $0 --tag env                               # Check for missing 'env' tag
    $0 --tag service --value elk-logging       # Check for specific tag value
    $0 --resources ec2,ebs                     # Only check EC2 instances and EBS volumes
    $0 --output csv --tag env > untagged.csv   # Export to CSV

SUPPORTED RESOURCE TYPES:
    - ec2: EC2 Instances
    - ebs: EBS Volumes
    - sg: Security Groups
    - vpc: VPCs
    - subnet: Subnets
    - elb: Load Balancers (ALB/NLB)
    - s3: S3 Buckets
EOF
}

# Parse command line arguments
TAG_KEY="$DEFAULT_TAG_KEY"
TAG_VALUE="$DEFAULT_TAG_VALUE"
OUTPUT_FORMAT="table"
# RESOURCE_TYPES="ec2,ebs,sg,vpc,subnet,elb,s3"
RESOURCE_TYPES="ec2"

while [[ $# -gt 0 ]]; do
    case $1 in
        -t|--tag)
            TAG_KEY="$2"
            shift 2
            ;;
        -v|--value)
            TAG_VALUE="$2"
            shift 2
            ;;
        -p|--profile)
            AWS_PROFILE="$2"
            shift 2
            ;;
        -r|--region)
            AWS_REGION="$2"
            shift 2
            ;;
        -o|--output)
            OUTPUT_FORMAT="$2"
            shift 2
            ;;
        --resources)
            RESOURCE_TYPES="$2"
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
            print_color $RED "Unknown argument: $1"
            show_help
            exit 1
            ;;
    esac
done

# Check if required tools are installed
if ! command -v aws &> /dev/null; then
    print_color $RED "Error: AWS CLI is not installed or not in PATH"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    print_color $RED "Error: jq is not installed or not in PATH"
    print_color $YELLOW "Install jq with: sudo apt-get install jq (Ubuntu/Debian) or brew install jq (macOS)"
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

# Display configuration (only for table format)
if [ "$OUTPUT_FORMAT" != "csv" ]; then
    print_color $YELLOW "Configuration:"
    echo "  AWS Profile: $AWS_PROFILE"
    echo "  AWS Region: $AWS_REGION"
    echo "  Tag Key: $TAG_KEY"
    echo "  Tag Value: ${TAG_VALUE:-[any value]}"
    echo "  Output Format: $OUTPUT_FORMAT"
    echo "  Resource Types: $RESOURCE_TYPES"
    echo ""
fi

# Setup output based on format
if [ "$OUTPUT_FORMAT" = "csv" ]; then
    echo "ResourceId,ResourceType,State,Details,Name"
elif [ "$OUTPUT_FORMAT" = "table" ]; then
    print_color $CYAN "Resources missing tag '$TAG_KEY'$([ -n "$TAG_VALUE" ] && echo " with value '$TAG_VALUE'"):"
    printf "%-20s %-15s %-12s %-15s %s\n" "RESOURCE-ID" "TYPE" "STATE" "DETAILS" "NAME"
    printf "%-20s %-15s %-12s %-15s %s\n" "--------------------" "---------------" "------------" "---------------" "----"
fi

# Check each resource type
total_untagged=0
IFS=',' read -ra TYPES <<< "$RESOURCE_TYPES"

for resource_type in "${TYPES[@]}"; do
    case $resource_type in
        ec2)
            if check_ec2_instances "$TAG_KEY" "$TAG_VALUE"; then
                ((total_untagged++))
            fi
            ;;
        ebs)
            if check_ebs_volumes "$TAG_KEY" "$TAG_VALUE"; then
                ((total_untagged++))
            fi
            ;;
        sg)
            if check_security_groups "$TAG_KEY" "$TAG_VALUE"; then
                ((total_untagged++))
            fi
            ;;
        vpc)
            if check_vpcs "$TAG_KEY" "$TAG_VALUE"; then
                ((total_untagged++))
            fi
            ;;
        subnet)
            if check_subnets "$TAG_KEY" "$TAG_VALUE"; then
                ((total_untagged++))
            fi
            ;;
        elb)
            if check_load_balancers "$TAG_KEY" "$TAG_VALUE"; then
                ((total_untagged++))
            fi
            ;;
        s3)
            if check_s3_buckets "$TAG_KEY" "$TAG_VALUE"; then
                ((total_untagged++))
            fi
            ;;
        *)
            print_color $RED "Unknown resource type: $resource_type"
            ;;
    esac
done

# Summary (only for non-CSV formats)
if [ "$OUTPUT_FORMAT" != "csv" ]; then
    echo ""
    if [ $total_untagged -eq 0 ]; then
        print_color $GREEN "✓ All checked resources have the required tag!"
    else
        print_color $YELLOW "⚠ Found untagged resources in $total_untagged resource type(s)"
        echo ""
        print_color $CYAN "To tag these resources, use the update-aws-tags script:"
        print_color $YELLOW "  ./update-aws-tags <resource-id1> <resource-id2> ..."
    fi
fi