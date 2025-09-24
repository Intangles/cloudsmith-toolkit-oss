#!/bin/bash
# AWS CLI command to retrieve existing tags for a resource by id: 
# aws ec2 describe-tags --filters "Name=resource-id,Values=INSTANCE_ID"
# 
# Print unique resource IDs, Volume IDs, and Network Interface IDs from CSV
# awk -F',' 'NR>1 {print $1 "\n" $6 "\n" $11}' to_tag.csv | sort -u | tr '\n' ' ' && echo

# AWS Resource Tagging Script
# Usage: ./update-aws-tags <resource-id1> <resource-id2> ... <resource-idN>
# Example: ./update-aws-tags i-1234567890abcdef0 vol-0987654321fedcba0

# Configuration
AWS_PROFILE="default"  # Change this to your AWS profile name
AWS_REGION="ap-south-1"  # Change this to your preferred region

# Common tags applied to all resources
COMMON_TAGS=(
    # "Key=env,Value=prod"
    # "Key=int:app@feature,Value=ml-models"
    # "Key=int:app@nature,Value=primary"
    # "Key=int:app@project,Value=default"
    # "Key=int:app@purpose,Value=machine-learning"
    # "Key=int:app@service,Value=mlflow-server"
    # "Key=int:ha@role,Value=server-node"
    # "Key=int:infra@nature,Value=shared"
    # "Key=int:infra@setup,Value=self-managed"
    # "Key=int:infra@tech,Value=mlflow"
    # # "Key=int:infra@db,Value=aggregatedb"
    # "Key=int:meta@tagged,Value=true"
    # "Key=int:org@bu,Value=analytics"
    # "Key=int:org@owner,Value=ravikant.itare"
    # "Key=int:org@team,Value=analytics"
    # "Key=int:security@data-sensitivity,Value=private"
    # "Key=int:meta@lifecycle,Value=permanent"

    # "Key=env,Value=prod"
    # "Key=int:app@feature,Value=obd-backup-publisher"
    # "Key=int:app@nature,Value=shared"
    # "Key=int:app@project,Value=default"
    # "Key=int:app@purpose,Value=data-tiering"
    # "Key=int:app@service,Value=s3-backup-and-deletion"
    # "Key=int:ha@role,Value=publisher"
    # "Key=int:infra@nature,Value=primary"
    # "Key=int:infra@setup,Value=self-managed"
    # "Key=int:infra@tech,Value=aws-spot-fleet"
    # "Key=int:infra@db,Value=obd-core"
    # "Key=int:meta@tagged,Value=true"
    # "Key=int:org@bu,Value=engineering"
    # "Key=int:org@owner,Value=engineering"
    # "Key=int:org@team,Value=infra-engineering"
    # "Key=int:security@data-sensitivity,Value=private"
    # "Key=int:meta@lifecycle,Value=temporary"
)

# Volume-specific tags (applied only to volumes, snapshots)
VOLUME_ONLY_TAGS=(
    "Key=int:infra@fs,Value=root"
    # "Key=int:infra@fs,Value=data"
    # "Key=int:infra@fs,Value=wal-oplog"
    # "Key=int:storage@backup,Value=enabled"
)

# Instance-specific tags (applied only to EC2 instances)
INSTANCE_ONLY_TAGS=(
    # "Key=int:compute@type,Value=database-server"
)

# Network-specific tags (applied only to network interfaces, security groups, VPCs, etc.)
NETWORK_ONLY_TAGS=(
    # "Key=int:network@tier,Value=private"
)

# Spot Fleet specific tags (applied only to spot fleet requests)
SPOT_FLEET_ONLY_TAGS=(
    # "Key=int:compute@allocation-strategy,Value=lowestPrice"
    # "Key=int:compute@target-capacity,Value=flexible"
)

# S3 specific tags (applied only to S3 buckets)
S3_BUCKET_ONLY_TAGS=(
    # "Key=int:storage@type,Value=object-storage"
    # "Key=int:storage@encryption,Value=enabled"
    # "Key=int:storage@versioning,Value=enabled"
    # "Key=int:storage@lifecycle,Value=configured"
)

# Legacy TAGS array for backward compatibility
TAGS=("${COMMON_TAGS[@]}")

# Function to get appropriate tags for resource type
get_tags_for_resource() {
    local resource_type=$1
    local tags=()
    
    # Add common tags
    tags+=("${COMMON_TAGS[@]}")
    
    # Add resource-specific tags
    case $resource_type in
        "volume"|"snapshot")
            tags+=("${VOLUME_ONLY_TAGS[@]}")
            ;;
        "ec2-instance")
            tags+=("${INSTANCE_ONLY_TAGS[@]}")
            ;;
        "network-interface"|"security-group"|"vpc"|"subnet")
            tags+=("${NETWORK_ONLY_TAGS[@]}")
            ;;
        "spot-fleet-request")
            tags+=("${SPOT_FLEET_ONLY_TAGS[@]}")
            ;;
        "s3-bucket")
            tags+=("${S3_BUCKET_ONLY_TAGS[@]}")
            ;;
    esac
    
    # Return tags array
    printf '%s\n' "${tags[@]}"
}

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
        arn:aws:elasticloadbalancing:*targetgroup*)
            echo "target-group"
            ;;
        arn:aws:autoscaling:*autoScalingGroup*)
            echo "auto-scaling-group"
            ;;
        lt-*)
            echo "launch-template"
            ;;
        nlb-*)
            echo "network-load-balancer"
            ;;
        sfr-*)
            echo "spot-fleet-request"
            ;;
        arn:aws:s3:::*)
            echo "s3-bucket"
            ;;
        *)
            # Check if it's an S3 bucket name or ASG name (no specific prefix pattern)
            # We'll validate this is actually an S3 bucket or ASG in the apply_tags function
            if [[ ! $resource_id =~ ^(i-|vol-|snap-|ami-|sg-|vpc-|subnet-|igw-|rtb-|eni-|eip-|lb-|nlb-|lt-|sfr-|arn:) ]]; then
                # Could be S3 bucket name or ASG name
                echo "potential-s3-or-asg"
            else
                echo "unknown"
            fi
            ;;
    esac
}

# Function to apply tags to different resource types
apply_tags() {
    local resource_id=$1
    local resource_type=$2
    
    print_color $BLUE "Applying tags to $resource_type: $resource_id"
    
    # Get appropriate tags for this resource type
    local resource_tags=()
    while IFS= read -r tag; do
        resource_tags+=("$tag")
    done < <(get_tags_for_resource "$resource_type")
    
    print_color $YELLOW "Using ${#resource_tags[@]} tags for $resource_type"
    
    case $resource_type in
        "ec2-instance"|"volume"|"snapshot"|"image"|"security-group"|"vpc"|"subnet"|"internet-gateway"|"route-table"|"network-interface")
            aws ec2 create-tags \
                --profile "$AWS_PROFILE" \
                --region "$AWS_REGION" \
                --resources "$resource_id" \
                --tags "${resource_tags[@]}"
            ;;
        "load-balancer"|"network-load-balancer"|"listener"|"listener-rule"|"target-group")
            # Convert tags to ELBv2 format (Key=key,Value=value)
            local elbv2_tags=()
            for tag in "${resource_tags[@]}"; do
                elbv2_tags+=("$tag")
            done
            
            # For ELBv2 (ALB/NLB/Listeners/Rules/Target Groups) - use ARN
            aws elbv2 add-tags \
                --profile "$AWS_PROFILE" \
                --region "$AWS_REGION" \
                --resource-arns "$resource_id" \
                --tags "${elbv2_tags[@]}" 2>/dev/null
            
            # If ELBv2 fails, try classic ELB (for backward compatibility)
            if [ $? -ne 0 ]; then
                aws elb add-tags \
                    --profile "$AWS_PROFILE" \
                    --region "$AWS_REGION" \
                    --load-balancer-names "$resource_id" \
                    --tags "${elbv2_tags[@]}"
            fi
            ;;
        "auto-scaling-group"|"potential-asg")
            # Extract ASG name from ARN if it's an ARN, otherwise use as-is
            local asg_name="$resource_id"
            if [[ $resource_id == arn:aws:autoscaling:* ]]; then
                # Extract ASG name from ARN: arn:aws:autoscaling:region:account:autoScalingGroup:uuid:autoScalingGroupName/name
                asg_name=$(echo "$resource_id" | sed 's/.*autoScalingGroupName\///')
                print_color $YELLOW "Extracted ASG name: $asg_name from ARN"
            fi
            
            # First, verify this is actually an ASG
            aws autoscaling describe-auto-scaling-groups \
                --profile "$AWS_PROFILE" \
                --region "$AWS_REGION" \
                --auto-scaling-group-names "$asg_name" \
                --query 'AutoScalingGroups[0].AutoScalingGroupName' \
                --output text > /dev/null 2>&1
                
            if [ $? -ne 0 ]; then
                print_color $RED "✗ Auto Scaling Group '$asg_name' not found"
                return 1
            fi
            
            # For ASGs, we need to apply tags individually
            local tag_success=true
            for tag in "${resource_tags[@]}"; do
                # Extract key and value from "Key=key,Value=value" format
                local key=$(echo "$tag" | sed 's/Key=\([^,]*\),Value=.*/\1/')
                local value=$(echo "$tag" | sed 's/Key=[^,]*,Value=\(.*\)/\1/')
                
                aws autoscaling create-or-update-tags \
                    --profile "$AWS_PROFILE" \
                    --region "$AWS_REGION" \
                    --tags "Key=$key,Value=$value,PropagateAtLaunch=true,ResourceId=$asg_name,ResourceType=auto-scaling-group"
                    
                if [ $? -ne 0 ]; then
                    tag_success=false
                    print_color $RED "✗ Failed to apply tag $key=$value to ASG $asg_name"
                fi
            done
            
            if [ "$tag_success" = false ]; then
                return 1
            fi
            ;;
        "launch-template")
            # For Launch Templates, use EC2 API
            aws ec2 create-tags \
                --profile "$AWS_PROFILE" \
                --region "$AWS_REGION" \
                --resources "$resource_id" \
                --tags "${resource_tags[@]}"
            ;;
        "spot-fleet-request")
            # For Spot Fleet Requests
            print_color $YELLOW "Applying tags to Spot Fleet Request: $resource_id"
            
            # Apply tags to spot fleet request
            aws ec2 create-tags \
                --profile "$AWS_PROFILE" \
                --region "$AWS_REGION" \
                --resources "$resource_id" \
                --tags "${resource_tags[@]}"
            
            local spot_tag_result=$?
            
            # Also apply tags to all instances in the spot fleet and their associated resources
            print_color $YELLOW "Getting instances from Spot Fleet: $resource_id"
            local spot_instances=$(aws ec2 describe-spot-fleet-instances \
                --profile "$AWS_PROFILE" \
                --region "$AWS_REGION" \
                --spot-fleet-request-id "$resource_id" \
                --query 'ActiveInstances[*].InstanceId' \
                --output text 2>/dev/null)
            
            if [ $? -eq 0 ] && [ -n "$spot_instances" ]; then
                print_color $YELLOW "Found spot fleet instances: $spot_instances"
                
                for instance_id in $spot_instances; do
                    print_color $YELLOW "Tagging spot fleet instance: $instance_id"
                    aws ec2 create-tags \
                        --profile "$AWS_PROFILE" \
                        --region "$AWS_REGION" \
                        --resources "$instance_id" \
                        --tags "${resource_tags[@]}"
                    
                    # Get and tag all volumes attached to this instance
                    print_color $YELLOW "Getting volumes for instance: $instance_id"
                    local volumes=$(aws ec2 describe-instances \
                        --profile "$AWS_PROFILE" \
                        --region "$AWS_REGION" \
                        --instance-ids "$instance_id" \
                        --query 'Reservations[*].Instances[*].BlockDeviceMappings[*].Ebs.VolumeId' \
                        --output text 2>/dev/null)
                    
                    if [ -n "$volumes" ]; then
                        print_color $YELLOW "Found volumes for instance $instance_id: $volumes"
                        # Get volume-specific tags
                        local volume_tags=()
                        while IFS= read -r tag; do
                            volume_tags+=("$tag")
                        done < <(get_tags_for_resource "volume")
                        
                        for volume_id in $volumes; do
                            if [ "$volume_id" != "None" ] && [ -n "$volume_id" ]; then
                                print_color $YELLOW "Tagging volume: $volume_id"
                                aws ec2 create-tags \
                                    --profile "$AWS_PROFILE" \
                                    --region "$AWS_REGION" \
                                    --resources "$volume_id" \
                                    --tags "${volume_tags[@]}"
                            fi
                        done
                    fi
                    
                    # Get and tag all network interfaces attached to this instance
                    print_color $YELLOW "Getting network interfaces for instance: $instance_id"
                    local network_interfaces=$(aws ec2 describe-instances \
                        --profile "$AWS_PROFILE" \
                        --region "$AWS_REGION" \
                        --instance-ids "$instance_id" \
                        --query 'Reservations[*].Instances[*].NetworkInterfaces[*].NetworkInterfaceId' \
                        --output text 2>/dev/null)
                    
                    if [ -n "$network_interfaces" ]; then
                        print_color $YELLOW "Found network interfaces for instance $instance_id: $network_interfaces"
                        # Get network-specific tags
                        local network_tags=()
                        while IFS= read -r tag; do
                            network_tags+=("$tag")
                        done < <(get_tags_for_resource "network-interface")
                        
                        for eni_id in $network_interfaces; do
                            if [ "$eni_id" != "None" ] && [ -n "$eni_id" ]; then
                                print_color $YELLOW "Tagging network interface: $eni_id"
                                aws ec2 create-tags \
                                    --profile "$AWS_PROFILE" \
                                    --region "$AWS_REGION" \
                                    --resources "$eni_id" \
                                    --tags "${network_tags[@]}"
                            fi
                        done
                    fi
                done
            else
                print_color $YELLOW "No active instances found in spot fleet or failed to retrieve instances"
            fi
            
            return $spot_tag_result
            ;;
        "s3-bucket"|"potential-s3-or-asg")
            # Handle S3 buckets and potential S3/ASG resources
            local bucket_name="$resource_id"
            
            # Extract bucket name from S3 ARN if it's an ARN, otherwise use as-is
            if [[ $resource_id == arn:aws:s3:::* ]]; then
                bucket_name=$(echo "$resource_id" | sed 's/arn:aws:s3::://' | cut -d'/' -f1)
                print_color $YELLOW "Extracted S3 bucket name: $bucket_name from ARN"
            fi
            
            # First, try to check if this is an S3 bucket
            aws s3api head-bucket \
                --profile "$AWS_PROFILE" \
                --bucket "$bucket_name" > /dev/null 2>&1
            
            if [ $? -eq 0 ]; then
                # It's an S3 bucket
                print_color $YELLOW "Confirmed S3 bucket: $bucket_name"
                
                # Convert tags to S3 format for tagging
                local s3_tags=()
                for tag in "${resource_tags[@]}"; do
                    # Extract key and value from "Key=key,Value=value" format
                    local key=$(echo "$tag" | sed 's/Key=\([^,]*\),Value=.*/\1/')
                    local value=$(echo "$tag" | sed 's/Key=[^,]*,Value=\(.*\)/\1/')
                    s3_tags+=("{\"Key\":\"$key\",\"Value\":\"$value\"}")
                done
                
                # Join tags with commas for JSON array
                local tags_json="[$(IFS=,; echo "${s3_tags[*]}")]"
                
                # Apply tags to S3 bucket
                aws s3api put-bucket-tagging \
                    --profile "$AWS_PROFILE" \
                    --bucket "$bucket_name" \
                    --tagging "TagSet=$tags_json"
                
                return $?
            else
                # Not an S3 bucket, try ASG if it's potential-s3-or-asg
                if [ "$resource_type" = "potential-s3-or-asg" ]; then
                    print_color $YELLOW "Not an S3 bucket, trying as Auto Scaling Group: $resource_id"
                    
                    # Try ASG
                    aws autoscaling describe-auto-scaling-groups \
                        --profile "$AWS_PROFILE" \
                        --region "$AWS_REGION" \
                        --auto-scaling-group-names "$resource_id" \
                        --query 'AutoScalingGroups[0].AutoScalingGroupName' \
                        --output text > /dev/null 2>&1
                        
                    if [ $? -eq 0 ]; then
                        print_color $YELLOW "Confirmed Auto Scaling Group: $resource_id"
                        # Apply ASG tags
                        local tag_success=true
                        for tag in "${resource_tags[@]}"; do
                            # Extract key and value from "Key=key,Value=value" format
                            local key=$(echo "$tag" | sed 's/Key=\([^,]*\),Value=.*/\1/')
                            local value=$(echo "$tag" | sed 's/Key=[^,]*,Value=\(.*\)/\1/')
                            
                            aws autoscaling create-or-update-tags \
                                --profile "$AWS_PROFILE" \
                                --region "$AWS_REGION" \
                                --tags "Key=$key,Value=$value,PropagateAtLaunch=true,ResourceId=$resource_id,ResourceType=auto-scaling-group"
                                
                            if [ $? -ne 0 ]; then
                                tag_success=false
                                print_color $RED "✗ Failed to apply tag $key=$value to ASG $resource_id"
                            fi
                        done
                        
                        if [ "$tag_success" = false ]; then
                            return 1
                        fi
                        return 0
                    else
                        print_color $RED "✗ Resource '$resource_id' is neither an S3 bucket nor an Auto Scaling Group"
                        return 1
                    fi
                else
                    print_color $RED "✗ S3 bucket '$bucket_name' not found or access denied"
                    return 1
                fi
            fi
            ;;
        *)
            print_color $RED "Unknown resource type for $resource_id. Skipping..."
            return 1
            ;;
    esac
    
    if [ $? -eq 0 ]; then
        print_color $GREEN "✓ Successfully tagged $resource_id"
        return 0
    else
        print_color $RED "✗ Failed to tag $resource_id"
        return 1
    fi
}

# Function to verify tags were applied
verify_tags() {
    local resource_id=$1
    local resource_type=$2
    
    print_color $YELLOW "Verifying tags for $resource_id..."
    
    case $resource_type in
        "ec2-instance"|"volume"|"snapshot"|"image"|"security-group"|"vpc"|"subnet"|"internet-gateway"|"route-table"|"network-interface")
            aws ec2 describe-tags \
                --profile "$AWS_PROFILE" \
                --region "$AWS_REGION" \
                --filters "Name=resource-id,Values=$resource_id" \
                --query 'Tags[*].[Key,Value]' \
                --output table
            ;;
        "load-balancer"|"network-load-balancer"|"listener"|"listener-rule"|"target-group")
            aws elbv2 describe-tags \
                --profile "$AWS_PROFILE" \
                --region "$AWS_REGION" \
                --resource-arns "$resource_id" \
                --query 'TagDescriptions[0].Tags[*].[Key,Value]' \
                --output table 2>/dev/null
            
            if [ $? -ne 0 ]; then
                aws elb describe-tags \
                    --profile "$AWS_PROFILE" \
                    --region "$AWS_REGION" \
                    --load-balancer-names "$resource_id" \
                    --query 'TagDescriptions[0].Tags[*].[Key,Value]' \
                    --output table
            fi
            ;;
        "auto-scaling-group"|"potential-asg")
            # Extract ASG name from ARN if it's an ARN, otherwise use as-is
            local asg_name="$resource_id"
            if [[ $resource_id == arn:aws:autoscaling:* ]]; then
                asg_name=$(echo "$resource_id" | sed 's/.*autoScalingGroupName\///')
            fi
            
            aws autoscaling describe-tags \
                --profile "$AWS_PROFILE" \
                --region "$AWS_REGION" \
                --filters "Name=auto-scaling-group,Values=$asg_name" \
                --query 'Tags[*].[Key,Value]' \
                --output table
            ;;
        "launch-template")
            aws ec2 describe-tags \
                --profile "$AWS_PROFILE" \
                --region "$AWS_REGION" \
                --filters "Name=resource-id,Values=$resource_id" \
                --query 'Tags[*].[Key,Value]' \
                --output table
            ;;
        "spot-fleet-request")
            print_color $YELLOW "Verifying tags for Spot Fleet Request: $resource_id"
            
            # Verify tags on the spot fleet request itself
            aws ec2 describe-tags \
                --profile "$AWS_PROFILE" \
                --region "$AWS_REGION" \
                --filters "Name=resource-id,Values=$resource_id" \
                --query 'Tags[*].[Key,Value]' \
                --output table
            
            # Also show tags on spot fleet instances and their resources
            local spot_instances=$(aws ec2 describe-spot-fleet-instances \
                --profile "$AWS_PROFILE" \
                --region "$AWS_REGION" \
                --spot-fleet-request-id "$resource_id" \
                --query 'ActiveInstances[*].InstanceId' \
                --output text 2>/dev/null)
            
            if [ $? -eq 0 ] && [ -n "$spot_instances" ]; then
                print_color $YELLOW "Tags on spot fleet instances and their resources:"
                for instance_id in $spot_instances; do
                    echo "Instance: $instance_id"
                    aws ec2 describe-tags \
                        --profile "$AWS_PROFILE" \
                        --region "$AWS_REGION" \
                        --filters "Name=resource-id,Values=$instance_id" \
                        --query 'Tags[*].[Key,Value]' \
                        --output table
                    
                    # Show volume tags
                    local volumes=$(aws ec2 describe-instances \
                        --profile "$AWS_PROFILE" \
                        --region "$AWS_REGION" \
                        --instance-ids "$instance_id" \
                        --query 'Reservations[*].Instances[*].BlockDeviceMappings[*].Ebs.VolumeId' \
                        --output text 2>/dev/null)
                    
                    if [ -n "$volumes" ]; then
                        for volume_id in $volumes; do
                            if [ "$volume_id" != "None" ] && [ -n "$volume_id" ]; then
                                echo "  Volume: $volume_id"
                                aws ec2 describe-tags \
                                    --profile "$AWS_PROFILE" \
                                    --region "$AWS_REGION" \
                                    --filters "Name=resource-id,Values=$volume_id" \
                                    --query 'Tags[*].[Key,Value]' \
                                    --output table
                            fi
                        done
                    fi
                    
                    # Show network interface tags
                    local network_interfaces=$(aws ec2 describe-instances \
                        --profile "$AWS_PROFILE" \
                        --region "$AWS_REGION" \
                        --instance-ids "$instance_id" \
                        --query 'Reservations[*].Instances[*].NetworkInterfaces[*].NetworkInterfaceId' \
                        --output text 2>/dev/null)
                    
                    if [ -n "$network_interfaces" ]; then
                        for eni_id in $network_interfaces; do
                            if [ "$eni_id" != "None" ] && [ -n "$eni_id" ]; then
                                echo "  Network Interface: $eni_id"
                                aws ec2 describe-tags \
                                    --profile "$AWS_PROFILE" \
                                    --region "$AWS_REGION" \
                                    --filters "Name=resource-id,Values=$eni_id" \
                                    --query 'Tags[*].[Key,Value]' \
                                    --output table
                            fi
                        done
                    fi
                    echo ""
                done
            fi
            ;;
        "s3-bucket"|"potential-s3-or-asg")
            local bucket_name="$resource_id"
            
            # Extract bucket name from S3 ARN if it's an ARN, otherwise use as-is
            if [[ $resource_id == arn:aws:s3:::* ]]; then
                bucket_name=$(echo "$resource_id" | sed 's/arn:aws:s3::://' | cut -d'/' -f1)
                print_color $YELLOW "Extracted S3 bucket name: $bucket_name from ARN"
            fi
            
            # First, try to check if this is an S3 bucket
            aws s3api head-bucket \
                --profile "$AWS_PROFILE" \
                --bucket "$bucket_name" > /dev/null 2>&1
            
            if [ $? -eq 0 ]; then
                # It's an S3 bucket
                print_color $YELLOW "Verifying tags for S3 bucket: $bucket_name"
                aws s3api get-bucket-tagging \
                    --profile "$AWS_PROFILE" \
                    --bucket "$bucket_name" \
                    --query 'TagSet[*].[Key,Value]' \
                    --output table 2>/dev/null
                
                if [ $? -ne 0 ]; then
                    print_color $YELLOW "No tags found on S3 bucket: $bucket_name"
                fi
            else
                # Not an S3 bucket, try ASG if it's potential-s3-or-asg
                if [ "$resource_type" = "potential-s3-or-asg" ]; then
                    print_color $YELLOW "Not an S3 bucket, trying as Auto Scaling Group: $resource_id"
                    
                    # Try ASG verification
                    aws autoscaling describe-auto-scaling-groups \
                        --profile "$AWS_PROFILE" \
                        --region "$AWS_REGION" \
                        --auto-scaling-group-names "$resource_id" \
                        --query 'AutoScalingGroups[0].AutoScalingGroupName' \
                        --output text > /dev/null 2>&1
                        
                    if [ $? -eq 0 ]; then
                        print_color $YELLOW "Verifying tags for Auto Scaling Group: $resource_id"
                        aws autoscaling describe-tags \
                            --profile "$AWS_PROFILE" \
                            --region "$AWS_REGION" \
                            --filters "Name=auto-scaling-group,Values=$resource_id" \
                            --query 'Tags[*].[Key,Value]' \
                            --output table
                    else
                        print_color $RED "✗ Resource '$resource_id' is neither an S3 bucket nor an Auto Scaling Group"
                    fi
                else
                    print_color $RED "✗ S3 bucket '$bucket_name' not found or access denied"
                fi
            fi
            ;;
    esac
}

# Function to display help
show_help() {
    cat << EOF
AWS Resource Tagging Script

Usage: $0 [OPTIONS] <resource-id1> [resource-id2] ... [resource-idN]

OPTIONS:
    -p, --profile PROFILE    AWS profile to use (default: $AWS_PROFILE)
    -r, --region REGION      AWS region to use (default: $AWS_REGION)
    -v, --verify            Verify tags after applying
    -h, --help              Show this help message

EXAMPLES:
    $0 i-1234567890abcdef0
    $0 -p production -r us-east-1 vol-0987654321fedcba0
    $0 --verify i-123 vol-456 sg-789
    $0 arn:aws:elasticloadbalancing:ap-south-1:123456789012:targetgroup/my-targets/1234567890123456
    $0 my-auto-scaling-group
    $0 --verify my-asg-1 my-asg-2 arn:aws:autoscaling:ap-south-1:123456789012:autoScalingGroup:uuid:autoScalingGroupName/my-asg
    $0 lt-0de064e7b27b0c2e3
    $0 sfr-73fbd2ce-aa30-494c-8788-1cee4EXAMPLE
    $0 --verify sfr-73fbd2ce-aa30-494c-8788-1cee4EXAMPLE
    $0 my-s3-bucket-name
    $0 arn:aws:s3:::my-bucket-name
    $0 --verify my-s3-bucket-name
    
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
    - Target Groups (arn:aws:elasticloadbalancing:*targetgroup*)
    - Auto Scaling Groups (ASG name or arn:aws:autoscaling:*autoScalingGroup*)
    - Launch Templates (lt-*)
    - Spot Fleet Requests (sfr-*)
    - S3 Buckets (bucket name or arn:aws:s3:::bucket-name)

TAGGING STRATEGY:
    The script uses conditional tagging based on resource type:
    - COMMON TAGS: Applied to all resources
    - VOLUME-SPECIFIC TAGS: Applied only to volumes and snapshots
    - INSTANCE-SPECIFIC TAGS: Applied only to EC2 instances
    - NETWORK-SPECIFIC TAGS: Applied only to network resources
    - S3-SPECIFIC TAGS: Applied only to S3 buckets

CONFIGURED TAGS:

Common Tags (applied to all resources):
EOF
    
    for tag in "${COMMON_TAGS[@]}"; do
        echo "    - $tag"
    done
    
    cat << EOF

Volume-Only Tags (volumes and snapshots):
EOF
    
    for tag in "${VOLUME_ONLY_TAGS[@]}"; do
        echo "    - $tag"
    done
    
    cat << EOF

Instance-Only Tags (EC2 instances):
EOF
    
    for tag in "${INSTANCE_ONLY_TAGS[@]}"; do
        echo "    - $tag"
    done
    
    cat << EOF

Network-Only Tags (network interfaces, security groups, VPCs):
EOF
    
    for tag in "${NETWORK_ONLY_TAGS[@]}"; do
        echo "    - $tag"
    done
    
    cat << EOF

Spot Fleet-Only Tags (spot fleet requests):
EOF
    
    for tag in "${SPOT_FLEET_ONLY_TAGS[@]}"; do
        echo "    - $tag"
    done
    
    cat << EOF

S3-Only Tags (S3 buckets):
EOF
    
    for tag in "${S3_BUCKET_ONLY_TAGS[@]}"; do
        echo "    - $tag"
    done
}

# Parse command line arguments
VERIFY_TAGS=false
RESOURCE_IDS=()

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
        -v|--verify)
            VERIFY_TAGS=true
            shift
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
            RESOURCE_IDS+=("$1")
            shift
            ;;
    esac
done

# Check if resource IDs were provided
if [ ${#RESOURCE_IDS[@]} -eq 0 ]; then
    print_color $RED "Error: No resource IDs provided"
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
echo "  Resource IDs: ${RESOURCE_IDS[*]}"
echo "  Verify Tags: $VERIFY_TAGS"
echo ""

# Process each resource ID
success_count=0
total_count=${#RESOURCE_IDS[@]}

for resource_id in "${RESOURCE_IDS[@]}"; do
    print_color $BLUE "Processing resource: $resource_id"
    
    # Detect resource type
    resource_type=$(get_resource_type "$resource_id")
    
    if [ "$resource_type" = "unknown" ]; then
        print_color $RED "✗ Unknown resource type for $resource_id. Skipping..."
        continue
    fi
    
    print_color $YELLOW "Detected resource type: $resource_type"
    
    # Apply tags
    if apply_tags "$resource_id" "$resource_type"; then
        ((success_count++))
        
        # Verify tags if requested
        if [ "$VERIFY_TAGS" = true ]; then
            echo ""
            verify_tags "$resource_id" "$resource_type"
        fi
    fi
    
    echo ""
done

# Summary
print_color $BLUE "Summary:"
print_color $GREEN "Successfully tagged: $success_count/$total_count resources"

if [ $success_count -eq $total_count ]; then
    print_color $GREEN "✓ All resources tagged successfully!"
    exit 0
else
    print_color $YELLOW "⚠ Some resources failed to be tagged"
    exit 1
fi