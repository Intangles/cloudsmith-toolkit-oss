#!/bin/bash

# EC2 Spot Fleet Management Script
# This script provides comprehensive management for EC2 Spot Fleets including:
# - Creating spot fleet requests
# - Tagging spot fleets and their instances
# - Monitoring spot fleet status
# - Scaling spot fleet capacity

# Configuration
AWS_PROFILE="default"
AWS_REGION=$(aws configure get region --profile "$AWS_PROFILE")

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

# Function to list all spot fleet requests
list_spot_fleets() {
    print_color $BLUE "Listing all Spot Fleet Requests in region: $AWS_REGION"
    
    aws ec2 describe-spot-fleet-requests \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --query 'SpotFleetRequestConfigs[*].[SpotFleetRequestId,SpotFleetRequestState,CreateTime,TargetCapacity,FulfilledCapacity]' \
        --output table
}

# Function to get spot fleet details
get_spot_fleet_details() {
    local spot_fleet_id=$1
    
    if [ -z "$spot_fleet_id" ]; then
        print_color $RED "Error: Spot Fleet ID is required"
        return 1
    fi
    
    print_color $BLUE "Getting details for Spot Fleet: $spot_fleet_id"
    
    # Get spot fleet configuration
    aws ec2 describe-spot-fleet-requests \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --spot-fleet-request-ids "$spot_fleet_id" \
        --query 'SpotFleetRequestConfigs[0]' \
        --output json
    
    echo ""
    print_color $YELLOW "Active instances in Spot Fleet:"
    
    # Get active instances
    aws ec2 describe-spot-fleet-instances \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --spot-fleet-request-id "$spot_fleet_id" \
        --query 'ActiveInstances[*].[InstanceId,InstanceType,SpotInstanceRequestId]' \
        --output table
}

# Function to tag spot fleet and its instances
tag_spot_fleet() {
    local spot_fleet_id=$1
    shift
    local tags=("$@")
    
    if [ -z "$spot_fleet_id" ]; then
        print_color $RED "Error: Spot Fleet ID is required"
        return 1
    fi
    
    if [ ${#tags[@]} -eq 0 ]; then
        print_color $RED "Error: At least one tag is required"
        return 1
    fi
    
    print_color $BLUE "Tagging Spot Fleet: $spot_fleet_id"
    
    # Tag the spot fleet request itself
    aws ec2 create-tags \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --resources "$spot_fleet_id" \
        --tags "${tags[@]}"
    
    if [ $? -eq 0 ]; then
        print_color $GREEN "✓ Successfully tagged Spot Fleet Request"
    else
        print_color $RED "✗ Failed to tag Spot Fleet Request"
        return 1
    fi
    
    # Get and tag all active instances
    local instances=$(aws ec2 describe-spot-fleet-instances \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --spot-fleet-request-id "$spot_fleet_id" \
        --query 'ActiveInstances[*].InstanceId' \
        --output text)
    
    if [ -n "$instances" ]; then
        print_color $YELLOW "Tagging spot fleet instances: $instances"
        
        for instance_id in $instances; do
            aws ec2 create-tags \
                --profile "$AWS_PROFILE" \
                --region "$AWS_REGION" \
                --resources "$instance_id" \
                --tags "${tags[@]}"
            
            if [ $? -eq 0 ]; then
                print_color $GREEN "✓ Tagged instance: $instance_id"
            else
                print_color $RED "✗ Failed to tag instance: $instance_id"
            fi
        done
    else
        print_color $YELLOW "No active instances found in spot fleet"
    fi
}

# Function to modify spot fleet capacity
modify_spot_fleet_capacity() {
    local spot_fleet_id=$1
    local target_capacity=$2
    
    if [ -z "$spot_fleet_id" ] || [ -z "$target_capacity" ]; then
        print_color $RED "Error: Spot Fleet ID and target capacity are required"
        return 1
    fi
    
    print_color $BLUE "Modifying Spot Fleet capacity: $spot_fleet_id -> $target_capacity"
    
    aws ec2 modify-spot-fleet-request \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --spot-fleet-request-id "$spot_fleet_id" \
        --target-capacity "$target_capacity"
    
    if [ $? -eq 0 ]; then
        print_color $GREEN "✓ Successfully modified spot fleet capacity"
    else
        print_color $RED "✗ Failed to modify spot fleet capacity"
        return 1
    fi
}

# Function to cancel spot fleet request
cancel_spot_fleet() {
    local spot_fleet_id=$1
    local terminate_instances=${2:-false}
    
    if [ -z "$spot_fleet_id" ]; then
        print_color $RED "Error: Spot Fleet ID is required"
        return 1
    fi
    
    print_color $BLUE "Canceling Spot Fleet: $spot_fleet_id (terminate instances: $terminate_instances)"
    
    aws ec2 cancel-spot-fleet-requests \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --spot-fleet-request-ids "$spot_fleet_id" \
        --terminate-instances "$terminate_instances"
    
    if [ $? -eq 0 ]; then
        print_color $GREEN "✓ Successfully canceled spot fleet request"
    else
        print_color $RED "✗ Failed to cancel spot fleet request"
        return 1
    fi
}

# Function to create a basic spot fleet request
create_spot_fleet() {
    local config_file=$1
    
    if [ -z "$config_file" ]; then
        print_color $RED "Error: Configuration file is required"
        return 1
    fi
    
    if [ ! -f "$config_file" ]; then
        print_color $RED "Error: Configuration file does not exist: $config_file"
        return 1
    fi
    
    print_color $BLUE "Creating Spot Fleet from configuration: $config_file"
    
    local spot_fleet_id=$(aws ec2 request-spot-fleet \
        --profile "$AWS_PROFILE" \
        --region "$AWS_REGION" \
        --spot-fleet-request-config "file://$config_file" \
        --query 'SpotFleetRequestId' \
        --output text)
    
    if [ $? -eq 0 ] && [ -n "$spot_fleet_id" ]; then
        print_color $GREEN "✓ Successfully created Spot Fleet: $spot_fleet_id"
        echo "$spot_fleet_id"
    else
        print_color $RED "✗ Failed to create spot fleet"
        return 1
    fi
}

# Function to generate a sample spot fleet configuration
generate_sample_config() {
    local output_file=${1:-"spot-fleet-config.json"}
    
    cat > "$output_file" << 'EOF'
{
    "SpotPrice": "0.012",
    "TargetCapacity": 2,
    "IamFleetRole": "arn:aws:iam::123456789012:role/aws-ec2-spot-fleet-role",
    "AllocationStrategy": "lowestPrice",
    "TargetCapacityUnitType": "units",
    "ReplaceUnhealthyInstances": true,
    "InstanceInterruptionBehavior": "terminate",
    "Type": "maintain",
    "LaunchSpecifications": [
        {
            "ImageId": "ami-0abcdef1234567890",
            "InstanceType": "t3.micro",
            "KeyName": "my-key-pair",
            "SecurityGroups": [
                {
                    "GroupId": "sg-12345678"
                }
            ],
            "SubnetId": "subnet-12345678",
            "IamInstanceProfile": {
                "Arn": "arn:aws:iam::123456789012:instance-profile/my-instance-profile"
            },
            "UserData": "IyEvYmluL2Jhc2gKZWNobyAiSGVsbG8gZnJvbSBTcG90IEZsZWV0ISIgPiAvaG9tZS9lYzItdXNlci9oZWxsby50eHQ=",
            "WeightedCapacity": 1.0
        },
        {
            "ImageId": "ami-0abcdef1234567890",
            "InstanceType": "t3.small",
            "KeyName": "my-key-pair",
            "SecurityGroups": [
                {
                    "GroupId": "sg-12345678"
                }
            ],
            "SubnetId": "subnet-87654321",
            "IamInstanceProfile": {
                "Arn": "arn:aws:iam::123456789012:instance-profile/my-instance-profile"
            },
            "UserData": "IyEvYmluL2Jhc2gKZWNobyAiSGVsbG8gZnJvbSBTcG90IEZsZWV0ISIgPiAvaG9tZS9lYzItdXNlci9oZWxsby50eHQ=",
            "WeightedCapacity": 2.0
        }
    ]
}
EOF
    
    print_color $GREEN "✓ Sample configuration generated: $output_file"
    print_color $YELLOW "Please edit the configuration file with your specific values before using it."
}

# Function to monitor spot fleet
monitor_spot_fleet() {
    local spot_fleet_id=$1
    local interval=${2:-30}
    
    if [ -z "$spot_fleet_id" ]; then
        print_color $RED "Error: Spot Fleet ID is required"
        return 1
    fi
    
    print_color $BLUE "Monitoring Spot Fleet: $spot_fleet_id (refresh interval: ${interval}s)"
    print_color $YELLOW "Press Ctrl+C to stop monitoring"
    
    while true; do
        clear
        echo "Monitoring Spot Fleet: $spot_fleet_id"
        echo "Last updated: $(date)"
        echo "=================================="
        
        # Get spot fleet status
        aws ec2 describe-spot-fleet-requests \
            --profile "$AWS_PROFILE" \
            --region "$AWS_REGION" \
            --spot-fleet-request-ids "$spot_fleet_id" \
            --query 'SpotFleetRequestConfigs[0].[SpotFleetRequestState,TargetCapacity,FulfilledCapacity]' \
            --output table
        
        echo ""
        echo "Active Instances:"
        
        # Get active instances
        aws ec2 describe-spot-fleet-instances \
            --profile "$AWS_PROFILE" \
            --region "$AWS_REGION" \
            --spot-fleet-request-id "$spot_fleet_id" \
            --query 'ActiveInstances[*].[InstanceId,InstanceType,SpotInstanceRequestId]' \
            --output table
        
        sleep "$interval"
    done
}

# Function to show help
show_help() {
    cat << EOF
EC2 Spot Fleet Management Script

USAGE:
    $0 <command> [options]

COMMANDS:
    list                                    List all spot fleet requests
    details <spot-fleet-id>                 Get detailed information about a spot fleet
    tag <spot-fleet-id> <tags...>          Tag spot fleet and its instances
    scale <spot-fleet-id> <capacity>        Modify spot fleet target capacity
    cancel <spot-fleet-id> [terminate]     Cancel spot fleet (optional: terminate instances)
    create <config-file>                   Create spot fleet from configuration file
    generate-config [output-file]          Generate sample configuration file
    monitor <spot-fleet-id> [interval]     Monitor spot fleet status (default interval: 30s)

OPTIONS:
    -p, --profile PROFILE                   AWS profile to use (default: $AWS_PROFILE)
    -r, --region REGION                     AWS region to use (default: $AWS_REGION)
    -h, --help                              Show this help message

EXAMPLES:
    $0 list
    $0 details sfr-73fbd2ce-aa30-494c-8788-1cee4EXAMPLE
    $0 tag sfr-73fbd2ce-aa30-494c-8788-1cee4EXAMPLE Key=Environment,Value=Production Key=Team,Value=DevOps
    $0 scale sfr-73fbd2ce-aa30-494c-8788-1cee4EXAMPLE 5
    $0 cancel sfr-73fbd2ce-aa30-494c-8788-1cee4EXAMPLE true
    $0 generate-config my-spot-fleet-config.json
    $0 create my-spot-fleet-config.json
    $0 monitor sfr-73fbd2ce-aa30-494c-8788-1cee4EXAMPLE 60

TAG FORMAT:
    Tags should be in the format: Key=TagKey,Value=TagValue
    Example: Key=Environment,Value=Production

INTEGRATION WITH update-aws-tags SCRIPT:
    This script works alongside the update-aws-tags script. You can use the main
    tagging script to apply standardized tags to spot fleets:
    
    ./update-aws-tags sfr-73fbd2ce-aa30-494c-8788-1cee4EXAMPLE

EOF
}

# Parse command line arguments
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
            break
            ;;
    esac
done

# Check if command was provided
if [ $# -eq 0 ]; then
    print_color $RED "Error: No command provided"
    show_help
    exit 1
fi

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    print_color $RED "Error: AWS CLI is not installed or not in PATH"
    exit 1
fi

# Verify AWS credentials
aws sts get-caller-identity --profile "$AWS_PROFILE" --region "$AWS_REGION" > /dev/null 2>&1

if [ $? -ne 0 ]; then
    print_color $RED "Error: AWS credentials not configured or invalid for profile: $AWS_PROFILE"
    exit 1
fi

# Execute command
command=$1
shift

case $command in
    "list")
        list_spot_fleets
        ;;
    "details")
        get_spot_fleet_details "$1"
        ;;
    "tag")
        spot_fleet_id=$1
        shift
        tag_spot_fleet "$spot_fleet_id" "$@"
        ;;
    "scale")
        modify_spot_fleet_capacity "$1" "$2"
        ;;
    "cancel")
        cancel_spot_fleet "$1" "$2"
        ;;
    "create")
        create_spot_fleet "$1"
        ;;
    "generate-config")
        generate_sample_config "$1"
        ;;
    "monitor")
        monitor_spot_fleet "$1" "$2"
        ;;
    *)
        print_color $RED "Unknown command: $command"
        show_help
        exit 1
        ;;
esac