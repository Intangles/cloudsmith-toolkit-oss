# Cloudsmith Toolkit 🛠️

> **🌟 OPEN SOURCE TOOLKIT** - *Free, community-driven DevOps automation for everyone*

**📢 This is a completely open source toolkit** designed to democratize cloud infrastructure management. Built by the community, for the community - with no vendor lock-in, no licensing fees, and full transparency.

A comprehensive collection of DevOps utilities and scripts for managing cloud infrastructure, databases, and monitoring across AWS, MongoDB, and other services. This toolkit provides automation scripts for resource tagging, database management, monitoring setup, and infrastructure maintenance.

## 📋 Table of Contents

- [Overview](#overview)
- [Repository Structure](#repository-structure)
- [Quick Start](#quick-start)
- [Tools and Scripts](#tools-and-scripts)
  - [AWS Management](#aws-management)
  - [MongoDB Management](#mongodb-management)
  - [Documentation](#documentation)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Usage Examples](#usage-examples)
- [Configuration](#configuration)
- [Contributing](#contributing)
- [Security Notes](#security-notes)
- [License](#license)

## 🔍 Overview

The Cloudsmith Toolkit is designed to streamline cloud infrastructure management through automated scripts and utilities. It focuses on:

- **AWS Resource Management**: Comprehensive tagging, monitoring, and resource discovery (EC2, EBS, S3, VPC, etc.)
- **Database Operations**: MongoDB replica set management and performance monitoring
- **Infrastructure Monitoring**: Automated setup of monitoring agents and configurations
- **Cost Optimization**: Spot fleet management and resource optimization tools

## 📁 Repository Structure

```
cloudsmith-toolkit/
├── aws/                                    # AWS management scripts
│   ├── ec2-tags.json                      # Sample EC2 tag configurations
│   ├── fetch-aws-tags.sh                  # Retrieve tags from AWS resources
│   ├── find-volumes-by-ec2-tag.sh         # Find volumes by EC2 instance tags
│   ├── list-untagged-resources.sh         # Identify untagged AWS resources
│   ├── spot-fleet-manager.sh              # Manage EC2 Spot Fleet requests
│   ├── tag-ecr-repos.sh                   # Apply tags to ECR repositories
│   ├── to_tag.csv                         # Resource list for bulk tagging
│   ├── untagged-ec2.csv                   # Sample report of untagged resources
│   └── update-aws-tags.sh                 # Bulk tag update utility
├── docs/                                   # Documentation
│   └── README-pgbouncer-timescale-setup.md # PGBouncer setup guide
├── mongodb/                                # MongoDB management scripts
│   ├── change-sync-source.js              # Change replica set sync source
│   ├── collection-size-report.js          # Generate collection size reports
│   └── detailed-collection-report.js      # Detailed database analytics
├── setup-datadog.sh                       # Datadog agent installation
├── .gitignore                             # Git ignore rules
└── README.md                              # This file
```

## 🚀 Quick Start

1. **Clone the repository:**
   ```bash
   git clone https://github.com/mudassir-ngineous/cloudsmith-toolkit.git
   cd cloudsmith-toolkit
   ```

2. **Make scripts executable:**
   ```bash
   find . -name "*.sh" -type f -exec chmod +x {} \;
   ```

3. **Configure AWS credentials:**
   ```bash
   aws configure
   # or
   export AWS_PROFILE=your-profile-name
   ```

4. **Run your first script:**
   ```bash
   ./aws/list-untagged-resources.sh --help
   ```

## 🛠️ Tools and Scripts

### AWS Management

#### 🏷️ Resource Tagging Tools

| Script | Purpose | Key Features |
|--------|---------|--------------|
| `fetch-aws-tags.sh` | Retrieve existing tags from AWS resources | • Auto-detects resource type<br>• Supports multiple resource types<br>• Colored output |
| `update-aws-tags.sh` | Bulk update tags on AWS resources | • Batch processing<br>• Configurable tag templates<br>• Error handling |
| `list-untagged-resources.sh` | Find resources missing required tags | • Multi-resource type scanning (EC2, EBS, S3, etc.)<br>• CSV export<br>• Filtering options<br>• S3 bucket support |
| `tag-ecr-repos.sh` | Tag ECR repositories automatically | • Bulk ECR tagging<br>• Service-based naming<br>• Profile support |

**Usage Example:**
```bash
# Find all untagged EC2 instances
./aws/list-untagged-resources.sh --tag service --output csv

# Find untagged S3 buckets
./aws/list-untagged-resources.sh --tag Environment --resources s3

# Find all untagged resources across multiple types
./aws/list-untagged-resources.sh --tag service --resources ec2,s3,ebs

# Tag multiple resources
./aws/update-aws-tags.sh i-1234567890abcdef0 vol-0987654321fedcba0

# Fetch tags for a specific resource
./aws/fetch-aws-tags.sh i-1234567890abcdef0
```

#### 💰 Cost Optimization Tools

| Script | Purpose | Key Features |
|--------|---------|--------------|
| `spot-fleet-manager.sh` | Manage EC2 Spot Fleet requests | • Create/modify spot fleets<br>• Capacity scaling<br>• Instance monitoring |
| `find-volumes-by-ec2-tag.sh` | Find EBS volumes by EC2 tags | • Tag-based volume discovery<br>• Multiple output formats<br>• Cost analysis support |

**Usage Example:**
```bash
# List all spot fleets
./aws/spot-fleet-manager.sh list

# Find volumes for production instances
./aws/find-volumes-by-ec2-tag.sh -t Environment -v Production
```

### MongoDB Management

#### 📊 Database Analytics

| Script | Purpose | Key Features |
|--------|---------|--------------|
| `collection-size-report.js` | Generate collection size reports | • CSV export format<br>• Size sorting<br>• Multiple databases |
| `detailed-collection-report.js` | Comprehensive database analysis | • Index analysis<br>• Performance metrics<br>• Storage optimization |

#### 🔄 Replica Set Management

| Script | Purpose | Key Features |
|--------|---------|--------------|
| `change-sync-source.js` | Modify replica set sync sources | • Sync source optimization<br>• Network topology aware<br>• Failover management |

**Usage Example:**
```bash
# Generate collection size report
mongo --quiet collection-size-report.js > collection_sizes.csv

# Change sync source for replica set member
mongo replica-set-member:27017 change-sync-source.js
```

### Documentation

#### 📚 Setup Guides

| Document | Purpose | Key Features |
|----------|---------|--------------|
| `README-pgbouncer-timescale-setup.md` | PGBouncer setup for TimescaleDB | • Zero-downtime deployment<br>• Read/write routing<br>• High availability |

## 📋 Prerequisites

### System Requirements
- **Operating System**: Linux/macOS
- **Shell**: Bash 4.0+ or compatible
- **Network**: Internet access for package downloads

### Required Tools
- **AWS CLI** v2.0+
- **MongoDB Shell** (for MongoDB scripts)
- **jq** (for JSON processing)
- **curl** (for downloads)

### Installation Commands
```bash
# AWS CLI
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install

# MongoDB Shell
# Ubuntu/Debian
sudo apt-get install mongodb-clients

# CentOS/RHEL
sudo yum install mongodb-org-shell

# jq
sudo apt-get install jq  # Ubuntu/Debian
sudo yum install jq      # CentOS/RHEL
```

## ⚙️ Configuration

### AWS Configuration

1. **Profile Setup:**
   ```bash
   aws configure --profile production
   ```

2. **Environment Variables:**
   ```bash
   export AWS_PROFILE=production
   export AWS_REGION=ap-south-1
   ```

3. **Script Configuration:**
   Edit the configuration section in each script:
   ```bash
   # Configuration
   AWS_PROFILE="default"
   AWS_REGION="ap-south-1"
   ```

### MongoDB Configuration

1. **Connection Settings:**
   Update connection strings in MongoDB scripts:
   ```javascript
   // Connect to specific replica set member
   var conn = new Mongo("replica-set-member:27017");
   ```

2. **Authentication:**
   Ensure proper authentication is configured:
   ```javascript
   db.auth("username", "password");
   ```

## 💡 Usage Examples

### Comprehensive AWS Resource Audit

```bash
# 1. Find all untagged resources (including S3 buckets)
./aws/list-untagged-resources.sh --output csv > audit_report.csv

# 2. Specifically audit S3 buckets for compliance
./aws/list-untagged-resources.sh --tag Environment --resources s3 --output table

# 3. Get detailed information about specific resources
./aws/fetch-aws-tags.sh i-1234567890abcdef0

# 4. Apply tags to resources
./aws/update-aws-tags.sh i-1234567890abcdef0 vol-0987654321fedcba0

# 5. Tag all ECR repositories
./aws/tag-ecr-repos.sh --profile production
```

### MongoDB Performance Analysis

```bash
# 1. Generate collection size report
mongo --quiet mongodb/collection-size-report.js > sizes.csv

# 2. Run detailed analysis
mongo mongodb/detailed-collection-report.js

# 3. Optimize replica set topology
mongo secondary-node:27017 mongodb/change-sync-source.js
```

## 🔒 Security Notes

### Sensitive Information
- **Never commit credentials** to version control
- Use environment variables or AWS profiles for authentication
- Review `.gitignore` to ensure sensitive files are excluded

### File Permissions
```bash
# Set appropriate permissions for scripts
chmod 750 *.sh
chmod 644 *.md *.json *.csv
```

### AWS Permissions
Ensure your AWS user/role has appropriate permissions:
- EC2: `DescribeInstances`, `DescribeTags`, `CreateTags`
- ECR: `DescribeRepositories`, `TagResource`
- EBS: `DescribeVolumes`
- S3: `ListAllMyBuckets`, `GetBucketTagging`, `PutBucketTagging`

## 🤝 Contributing

1. **Fork the repository**
2. **Create a feature branch:** `git checkout -b feature/new-script`
3. **Make your changes** and test thoroughly
4. **Add documentation** for new scripts
5. **Commit changes:** `git commit -am 'Add new AWS utility script'`
6. **Push to branch:** `git push origin feature/new-script`
7. **Submit a Pull Request**

### Script Development Guidelines

- **Use consistent error handling** and exit codes
- **Include help documentation** with `--help` flag
- **Add colored output** for better user experience
- **Support multiple output formats** where applicable
- **Include usage examples** in script comments

## 📞 Support

For issues, questions, or contributions:
- **Repository**: [cloudsmith-toolkit](https://github.com/mudassir-ngineous/cloudsmith-toolkit)
- **Issues**: Use GitHub Issues for bug reports and feature requests

## 📝 License

This project is licensed under the MIT License - see the LICENSE file for details.

---

**⚡ Quick Commands:**
```bash
# Make all scripts executable
find . -name "*.sh" -type f -exec chmod +x {} \;

# List all available tools
find . -name "*.sh" -type f -exec basename {} \; | sort

# Get help for any script
./aws/list-untagged-resources.sh --help
```