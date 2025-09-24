#!/bin/bash

# Script to apply service tags to all AWS ECR repositories
# Tag format: service = ecr:{repository-name}

set -e

# Function to display usage
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  -p, --profile PROFILE    AWS profile to use (optional)"
    echo "  -h, --help              Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                      # Use default AWS profile"
    echo "  $0 -p production        # Use 'production' AWS profile"
    echo "  $0 --profile staging    # Use 'staging' AWS profile"
}

# Initialize variables
AWS_PROFILE="default"
AWS_PROFILE_FLAG=""

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -p|--profile)
            AWS_PROFILE="$2"
            AWS_PROFILE_FLAG="--profile $AWS_PROFILE"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Display selected profile
if [ -n "$AWS_PROFILE" ]; then
    echo "Using AWS profile: $AWS_PROFILE"
else
    echo "Using default AWS profile"
fi

echo "Starting ECR repository tagging process..."

# Get all ECR repositories
repositories=$(aws ecr describe-repositories $AWS_PROFILE_FLAG --query 'repositories[].repositoryName' --output text)

if [ -z "$repositories" ]; then
    echo "No ECR repositories found."
    exit 0
fi

echo "Found ECR repositories:"
echo "$repositories"
echo ""

# Counter for tracking progress
count=0
total=$(echo "$repositories" | wc -w)

# Iterate through each repository
for repo in $repositories; do
    count=$((count + 1))
    echo "[$count/$total] Processing repository: $repo"
    
    # Create the service tag value
    service_tag_value="ecr:$repo"
    
    # Get the repository ARN
    repo_arn=$(aws ecr describe-repositories $AWS_PROFILE_FLAG --repository-names "$repo" --query 'repositories[0].repositoryArn' --output text)
    
    if [ -n "$repo_arn" ]; then
        # Apply the service tag
        aws ecr tag-resource $AWS_PROFILE_FLAG \
            --resource-arn "$repo_arn" \
            --tags Key=service,Value="$service_tag_value"
        
        echo "  ✓ Tagged with service=$service_tag_value"
    else
        echo "  ✗ Failed to get ARN for repository: $repo"
    fi
    
    echo ""
done

echo "Tagging process completed!"
echo "Total repositories processed: $total"

# Optional: Verify tags were applied
echo ""
echo "Verifying tags (showing first 5 repositories)..."
first_five=$(echo "$repositories" | head -n5)
for repo in $first_five; do
    repo_arn=$(aws ecr describe-repositories $AWS_PROFILE_FLAG --repository-names "$repo" --query 'repositories[0].repositoryArn' --output text)
    tags=$(aws ecr list-tags-for-resource $AWS_PROFILE_FLAG --resource-arn "$repo_arn" --query 'tags[?Key==`service`].Value' --output text)
    echo "$repo: service=$tags"
done