# RabbitMQ Cluster on AWS Graviton - Complete Setup Guide

## Overview

This guide provides detailed steps to deploy a RabbitMQ 3.8.3-rc.2 cluster with Erlang 22.3.4.1 on Amazon Linux 2 Graviton (ARM64) instances using AWS ASG, Launch Templates, and Target Groups.

## Architecture

```
                    ┌─────────────────────────────────────────┐
                    │           Application Load Balancer     │
                    │         (AMQP: 5672, Management: 15672) │
                    └─────────────────┬───────────────────────┘
                                      │
                    ┌─────────────────┼───────────────────────┐
                    │                 │                       │
              ┌─────▼─────┐    ┌──────▼────┐    ┌────────────▼┐
              │ RabbitMQ  │◄──►│ RabbitMQ  │◄──►│  RabbitMQ   │
              │  Node 1   │    │  Node 2   │    │   Node 3    │
              │ (Graviton)│    │ (Graviton)│    │  (Graviton) │
              └───────────┘    └───────────┘    └─────────────┘
                    │                 │                │
                    └─────────────────┼────────────────┘
                                      │
                    ┌─────────────────▼───────────────────────┐
                    │        Amazon EFS (Shared Storage)      │
                    │        (Optional: for config sync)      │
                    └─────────────────────────────────────────┘
```

---

## Prerequisites

1. **AWS Account** with appropriate permissions
2. **VPC** with at least 3 private subnets across different AZs
3. **AWS CLI** configured with proper credentials
4. **Key Pair** for SSH access

---

## Step 1: Create Security Groups

### 1.1 RabbitMQ Security Group

```bash
# Create security group
SECURITY_GROUP_ID=$(aws ec2 create-security-group \
    --group-name rabbitmq-cluster-sg \
    --description "Security group for RabbitMQ cluster" \
    --vpc-id vpc-xxxxxxxxx \
    --query 'GroupId' \
    --output text)

# AMQP port (clients)
aws ec2 authorize-security-group-ingress \
    --group-id $SECURITY_GROUP_ID \
    --protocol tcp \
    --port 5672 \
    --cidr 10.0.0.0/8

# Management UI
aws ec2 authorize-security-group-ingress \
    --group-id $SECURITY_GROUP_ID \
    --protocol tcp \
    --port 15672 \
    --cidr 10.0.0.0/8

# Erlang distribution (clustering) - within security group
aws ec2 authorize-security-group-ingress \
    --group-id $SECURITY_GROUP_ID \
    --protocol tcp \
    --port 25672 \
    --source-group $SECURITY_GROUP_ID

# EPMD (Erlang Port Mapper) - within security group
aws ec2 authorize-security-group-ingress \
    --group-id $SECURITY_GROUP_ID \
    --protocol tcp \
    --port 4369 \
    --source-group $SECURITY_GROUP_ID

# Prometheus metrics
aws ec2 authorize-security-group-ingress \
    --group-id $SECURITY_GROUP_ID \
    --protocol tcp \
    --port 15692 \
    --cidr 10.0.0.0/8

# SSH access (from bastion/VPN only)
aws ec2 authorize-security-group-ingress \
    --group-id $SECURITY_GROUP_ID \
    --protocol tcp \
    --port 22 \
    --cidr 10.0.0.0/8
```

---

## Step 2: Create IAM Role for RabbitMQ Instances

### 2.1 Create IAM Policy

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "autoscaling:DescribeAutoScalingGroups",
                "autoscaling:DescribeAutoScalingInstances",
                "ec2:DescribeInstances",
                "ec2:DescribeTags"
            ],
            "Resource": "*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "ssm:GetParameter",
                "ssm:GetParameters",
                "ssm:GetParametersByPath"
            ],
            "Resource": "arn:aws:ssm:*:*:parameter/rabbitmq/*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "logs:CreateLogGroup",
                "logs:CreateLogStream",
                "logs:PutLogEvents"
            ],
            "Resource": "*"
        }
    ]
}
```

### 2.2 Create IAM Role

```bash
# Create trust policy file
cat > trust-policy.json << 'EOF'
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "ec2.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
EOF

# Create role
aws iam create-role \
    --role-name RabbitMQClusterRole \
    --assume-role-policy-document file://trust-policy.json

# Attach policy
aws iam put-role-policy \
    --role-name RabbitMQClusterRole \
    --policy-name RabbitMQClusterPolicy \
    --policy-document file://rabbitmq-policy.json

# Create instance profile
aws iam create-instance-profile \
    --instance-profile-name RabbitMQClusterProfile

aws iam add-role-to-instance-profile \
    --instance-profile-name RabbitMQClusterProfile \
    --role-name RabbitMQClusterRole
```

---

## Step 3: Store Erlang Cookie in SSM Parameter Store

```bash
# Generate a secure cookie
ERLANG_COOKIE=$(openssl rand -base64 32 | tr -d '=+/')

# Store in Parameter Store
aws ssm put-parameter \
    --name "/rabbitmq/erlang-cookie" \
    --value "$ERLANG_COOKIE" \
    --type "SecureString" \
    --description "Erlang cookie for RabbitMQ cluster" \
    --overwrite

# Store admin password
ADMIN_PASSWORD=$(openssl rand -base64 24)
aws ssm put-parameter \
    --name "/rabbitmq/admin-password" \
    --value "$ADMIN_PASSWORD" \
    --type "SecureString" \
    --description "RabbitMQ admin password" \
    --overwrite
```

---

## Step 4: Create Launch Template

### 4.1 User Data Script

Create `user-data.sh`:

```bash
#!/bin/bash
set -ex

# Logging
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

echo "Starting RabbitMQ installation..."

# Set hostname based on instance ID
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
PRIVATE_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)

# Set hostname
hostnamectl set-hostname rabbitmq-${INSTANCE_ID}
echo "${PRIVATE_IP} rabbitmq-${INSTANCE_ID}" >> /etc/hosts

# Install prerequisites
yum update -y
yum install -y wget curl git gcc gcc-c++ make ncurses-devel openssl-devel \
    unixODBC-devel java-11-amazon-corretto-headless socat logrotate jq awscli

# Install Erlang 22.3.4.1
cd /tmp
wget https://github.com/erlang/otp/releases/download/OTP-22.3.4.1/otp_src_22.3.4.1.tar.gz
tar -xzf otp_src_22.3.4.1.tar.gz
cd otp_src_22.3.4.1

./configure --prefix=/usr/local --enable-threads --enable-smp-support \
    --enable-kernel-poll --with-ssl --without-javac
make -j$(nproc)
make install

echo 'export PATH=/usr/local/bin:$PATH' > /etc/profile.d/erlang.sh
source /etc/profile.d/erlang.sh

# Install RabbitMQ 3.8.3-rc.2
cd /tmp
wget https://github.com/rabbitmq/rabbitmq-server/releases/download/v3.8.3-rc.2/rabbitmq-server-generic-unix-3.8.3-rc.2.tar.xz

groupadd -r rabbitmq || true
useradd -r -g rabbitmq -d /var/lib/rabbitmq -s /sbin/nologin rabbitmq || true

mkdir -p /opt/rabbitmq
tar -xJf rabbitmq-server-generic-unix-3.8.3-rc.2.tar.xz -C /opt/rabbitmq --strip-components=1

mkdir -p /var/lib/rabbitmq /var/log/rabbitmq /etc/rabbitmq /var/run/rabbitmq
chown -R rabbitmq:rabbitmq /opt/rabbitmq /var/lib/rabbitmq /var/log/rabbitmq /etc/rabbitmq /var/run/rabbitmq

# Create symlinks
ln -sf /opt/rabbitmq/sbin/rabbitmq-server /usr/local/bin/
ln -sf /opt/rabbitmq/sbin/rabbitmqctl /usr/local/bin/
ln -sf /opt/rabbitmq/sbin/rabbitmq-plugins /usr/local/bin/
ln -sf /opt/rabbitmq/sbin/rabbitmq-diagnostics /usr/local/bin/

# Get Erlang cookie from SSM
ERLANG_COOKIE=$(aws ssm get-parameter --name "/rabbitmq/erlang-cookie" \
    --with-decryption --region $REGION --query "Parameter.Value" --output text)
echo -n "$ERLANG_COOKIE" > /var/lib/rabbitmq/.erlang.cookie
chmod 400 /var/lib/rabbitmq/.erlang.cookie
chown rabbitmq:rabbitmq /var/lib/rabbitmq/.erlang.cookie

# Configure RabbitMQ
cat > /etc/rabbitmq/rabbitmq-env.conf << 'ENVCONF'
RABBITMQ_NODENAME=rabbit@$(hostname -s)
RABBITMQ_CONFIG_FILE=/etc/rabbitmq/rabbitmq
RABBITMQ_LOG_BASE=/var/log/rabbitmq
RABBITMQ_MNESIA_BASE=/var/lib/rabbitmq/mnesia
RABBITMQ_PID_FILE=/var/run/rabbitmq/pid
RABBITMQ_USE_LONGNAME=false
export ERL_EPMD_ADDRESS=0.0.0.0
export RABBITMQ_SERVER_START_ARGS="-kernel inet_dist_listen_min 25672 inet_dist_listen_max 25672"
ENVCONF

cat > /etc/rabbitmq/rabbitmq.conf << CONF
# Networking
listeners.tcp.default = 5672
management.tcp.port = 15672

# Clustering
cluster_formation.peer_discovery_backend = aws
cluster_formation.aws.region = ${REGION}
cluster_formation.aws.use_autoscaling_group = true
cluster_formation.aws.use_private_ip = true

cluster_formation.node_cleanup.interval = 30
cluster_formation.node_cleanup.only_log_warning = true

# Memory and disk
vm_memory_high_watermark.relative = 0.7
disk_free_limit.absolute = 5GB

# Logging
log.file.level = info
log.console = true
log.console.level = info

# Connections
heartbeat = 60
channel_max = 2047

# Queue
queue_master_locator = min-masters
CONF

# Enable plugins
cat > /etc/rabbitmq/enabled_plugins << 'PLUGINS'
[rabbitmq_management,rabbitmq_management_agent,rabbitmq_peer_discovery_aws,rabbitmq_prometheus].
PLUGINS

chown -R rabbitmq:rabbitmq /etc/rabbitmq

# Configure OS limits
cat > /etc/security/limits.d/rabbitmq.conf << 'LIMITS'
rabbitmq soft nofile 65536
rabbitmq hard nofile 65536
rabbitmq soft nproc 65536
rabbitmq hard nproc 65536
LIMITS

cat > /etc/sysctl.d/99-rabbitmq.conf << 'SYSCTL'
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
vm.swappiness = 1
SYSCTL
sysctl -p /etc/sysctl.d/99-rabbitmq.conf

# Create systemd service
cat > /etc/systemd/system/rabbitmq-server.service << 'SERVICE'
[Unit]
Description=RabbitMQ broker
After=network.target

[Service]
Type=notify
User=rabbitmq
Group=rabbitmq
NotifyAccess=all
TimeoutStartSec=3600
WorkingDirectory=/var/lib/rabbitmq
RuntimeDirectory=rabbitmq
RuntimeDirectoryMode=0755
Environment="RABBITMQ_HOME=/opt/rabbitmq"
Environment="HOME=/var/lib/rabbitmq"
Environment="PATH=/usr/local/bin:/opt/rabbitmq/sbin:/usr/bin:/bin"
ExecStart=/opt/rabbitmq/sbin/rabbitmq-server
ExecStop=/opt/rabbitmq/sbin/rabbitmqctl shutdown
Restart=on-failure
RestartSec=10
LimitNOFILE=65536
LimitNPROC=65536

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable rabbitmq-server
systemctl start rabbitmq-server

# Wait for RabbitMQ to start
sleep 30

# Create admin user
ADMIN_PASSWORD=$(aws ssm get-parameter --name "/rabbitmq/admin-password" \
    --with-decryption --region $REGION --query "Parameter.Value" --output text)
    
rabbitmqctl add_user admin "$ADMIN_PASSWORD" || true
rabbitmqctl set_user_tags admin administrator
rabbitmqctl set_permissions -p / admin ".*" ".*" ".*"
rabbitmqctl delete_user guest || true

echo "RabbitMQ installation completed!"
```

### 4.2 Create Launch Template via AWS CLI

```bash
# Base64 encode the user data
USER_DATA_B64=$(base64 -w 0 user-data.sh)

# Get latest Amazon Linux 2 ARM64 AMI
AMI_ID=$(aws ec2 describe-images \
    --owners amazon \
    --filters "Name=name,Values=amzn2-ami-hvm-*-arm64-gp2" \
              "Name=state,Values=available" \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
    --output text)

# Create launch template
aws ec2 create-launch-template \
    --launch-template-name rabbitmq-graviton-lt \
    --version-description "RabbitMQ 3.8.3-rc.2 on Graviton" \
    --launch-template-data '{
        "ImageId": "'$AMI_ID'",
        "InstanceType": "m6g.large",
        "KeyName": "your-key-pair",
        "IamInstanceProfile": {
            "Arn": "arn:aws:iam::ACCOUNT_ID:instance-profile/RabbitMQClusterProfile"
        },
        "SecurityGroupIds": ["'$SECURITY_GROUP_ID'"],
        "BlockDeviceMappings": [
            {
                "DeviceName": "/dev/xvda",
                "Ebs": {
                    "VolumeSize": 100,
                    "VolumeType": "gp3",
                    "Iops": 3000,
                    "Throughput": 125,
                    "DeleteOnTermination": true,
                    "Encrypted": true
                }
            }
        ],
        "MetadataOptions": {
            "HttpTokens": "required",
            "HttpPutResponseHopLimit": 2,
            "HttpEndpoint": "enabled"
        },
        "UserData": "'$USER_DATA_B64'",
        "TagSpecifications": [
            {
                "ResourceType": "instance",
                "Tags": [
                    {"Key": "Name", "Value": "rabbitmq-cluster-node"},
                    {"Key": "Service", "Value": "rabbitmq"},
                    {"Key": "Environment", "Value": "production"}
                ]
            }
        ]
    }'
```

---

## Step 5: Create Target Groups

### 5.1 AMQP Target Group (NLB)

```bash
# Create target group for AMQP (5672)
AMQP_TG_ARN=$(aws elbv2 create-target-group \
    --name rabbitmq-amqp-tg \
    --protocol TCP \
    --port 5672 \
    --vpc-id vpc-xxxxxxxxx \
    --target-type instance \
    --health-check-protocol TCP \
    --health-check-port 5672 \
    --health-check-interval-seconds 30 \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 2 \
    --query 'TargetGroups[0].TargetGroupArn' \
    --output text)

echo "AMQP Target Group ARN: $AMQP_TG_ARN"
```

### 5.2 Management UI Target Group (ALB)

```bash
# Create target group for Management UI (15672)
MGMT_TG_ARN=$(aws elbv2 create-target-group \
    --name rabbitmq-mgmt-tg \
    --protocol HTTP \
    --port 15672 \
    --vpc-id vpc-xxxxxxxxx \
    --target-type instance \
    --health-check-protocol HTTP \
    --health-check-port 15672 \
    --health-check-path /api/health/checks/alarms \
    --health-check-interval-seconds 30 \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 3 \
    --matcher HttpCode=200 \
    --query 'TargetGroups[0].TargetGroupArn' \
    --output text)

echo "Management Target Group ARN: $MGMT_TG_ARN"
```

---

## Step 6: Create Network Load Balancer (for AMQP)

```bash
# Create NLB
NLB_ARN=$(aws elbv2 create-load-balancer \
    --name rabbitmq-nlb \
    --type network \
    --scheme internal \
    --subnets subnet-aaaa subnet-bbbb subnet-cccc \
    --query 'LoadBalancers[0].LoadBalancerArn' \
    --output text)

# Create listener
aws elbv2 create-listener \
    --load-balancer-arn $NLB_ARN \
    --protocol TCP \
    --port 5672 \
    --default-actions Type=forward,TargetGroupArn=$AMQP_TG_ARN

echo "NLB ARN: $NLB_ARN"
echo "NLB DNS: $(aws elbv2 describe-load-balancers --load-balancer-arns $NLB_ARN --query 'LoadBalancers[0].DNSName' --output text)"
```

---

## Step 7: Create Application Load Balancer (for Management UI)

```bash
# Create ALB security group
ALB_SG_ID=$(aws ec2 create-security-group \
    --group-name rabbitmq-alb-sg \
    --description "Security group for RabbitMQ ALB" \
    --vpc-id vpc-xxxxxxxxx \
    --query 'GroupId' \
    --output text)

aws ec2 authorize-security-group-ingress \
    --group-id $ALB_SG_ID \
    --protocol tcp \
    --port 443 \
    --cidr 10.0.0.0/8

# Create ALB
ALB_ARN=$(aws elbv2 create-load-balancer \
    --name rabbitmq-alb \
    --type application \
    --scheme internal \
    --security-groups $ALB_SG_ID \
    --subnets subnet-aaaa subnet-bbbb subnet-cccc \
    --query 'LoadBalancers[0].LoadBalancerArn' \
    --output text)

# Create HTTPS listener (requires ACM certificate)
aws elbv2 create-listener \
    --load-balancer-arn $ALB_ARN \
    --protocol HTTPS \
    --port 443 \
    --certificates CertificateArn=arn:aws:acm:region:account:certificate/cert-id \
    --default-actions Type=forward,TargetGroupArn=$MGMT_TG_ARN

echo "ALB ARN: $ALB_ARN"
echo "ALB DNS: $(aws elbv2 describe-load-balancers --load-balancer-arns $ALB_ARN --query 'LoadBalancers[0].DNSName' --output text)"
```

---

## Step 8: Create Auto Scaling Group

```bash
# Create ASG
aws autoscaling create-auto-scaling-group \
    --auto-scaling-group-name rabbitmq-cluster-asg \
    --launch-template LaunchTemplateName=rabbitmq-graviton-lt,Version='$Latest' \
    --min-size 3 \
    --max-size 5 \
    --desired-capacity 3 \
    --vpc-zone-identifier "subnet-aaaa,subnet-bbbb,subnet-cccc" \
    --target-group-arns $AMQP_TG_ARN $MGMT_TG_ARN \
    --health-check-type ELB \
    --health-check-grace-period 600 \
    --tags Key=Name,Value=rabbitmq-cluster-node,PropagateAtLaunch=true \
           Key=Service,Value=rabbitmq,PropagateAtLaunch=true \
           Key=Environment,Value=production,PropagateAtLaunch=true

# Add lifecycle hook for graceful shutdown
aws autoscaling put-lifecycle-hook \
    --lifecycle-hook-name rabbitmq-terminating-hook \
    --auto-scaling-group-name rabbitmq-cluster-asg \
    --lifecycle-transition autoscaling:EC2_INSTANCE_TERMINATING \
    --heartbeat-timeout 300 \
    --default-result CONTINUE
```

---

## Step 9: Scaling Policies (Optional)

```bash
# Scale up policy
aws autoscaling put-scaling-policy \
    --auto-scaling-group-name rabbitmq-cluster-asg \
    --policy-name rabbitmq-scale-up \
    --policy-type TargetTrackingScaling \
    --target-tracking-configuration '{
        "TargetValue": 70.0,
        "PredefinedMetricSpecification": {
            "PredefinedMetricType": "ASGAverageCPUUtilization"
        },
        "ScaleInCooldown": 300,
        "ScaleOutCooldown": 60
    }'
```

---

## Step 10: Verification and Testing

### 10.1 Check Cluster Status

```bash
# SSH into any node
ssh -i your-key.pem ec2-user@<node-ip>

# Check cluster status
sudo rabbitmqctl cluster_status

# Check node health
sudo rabbitmq-diagnostics check_running
sudo rabbitmq-diagnostics check_local_alarms
sudo rabbitmq-diagnostics check_alarms

# List queue status
sudo rabbitmqctl list_queues name messages consumers
```

### 10.2 Test AMQP Connection

```python
import pika

# Connect via NLB
connection = pika.BlockingConnection(
    pika.ConnectionParameters(
        host='rabbitmq-nlb-xxxxxx.elb.region.amazonaws.com',
        port=5672,
        credentials=pika.PlainCredentials('admin', 'your-password')
    )
)

channel = connection.channel()
channel.queue_declare(queue='test-queue')
channel.basic_publish(exchange='', routing_key='test-queue', body='Hello RabbitMQ!')
print("Message sent successfully!")
connection.close()
```

---

## Troubleshooting

### Common Issues

1. **Nodes not joining cluster**
   - Check security group rules for ports 4369 and 25672
   - Verify Erlang cookie is identical across all nodes
   - Check `/var/log/rabbitmq/*.log` for errors

2. **IAM permission errors**
   - Ensure the IAM role has autoscaling:Describe* permissions
   - Verify SSM parameter access

3. **Network connectivity**
   - Ensure all nodes can resolve each other's hostnames
   - Check `/etc/hosts` entries

### Useful Commands

```bash
# View logs
sudo journalctl -u rabbitmq-server -f

# Reset a node (WARNING: removes all data)
sudo rabbitmqctl stop_app
sudo rabbitmqctl reset
sudo rabbitmqctl start_app

# Force remove a node from cluster
sudo rabbitmqctl forget_cluster_node rabbit@<node-name>

# Check cluster partition
sudo rabbitmqctl cluster_status | grep -A5 "Running"
```

---

## Security Best Practices

1. **Enable TLS** for inter-node and client connections
2. **Use strong passwords** stored in Secrets Manager
3. **Enable CloudWatch logs** for audit and monitoring
4. **Use VPC endpoints** for AWS services access
5. **Regularly rotate** the Erlang cookie and admin credentials
6. **Enable MFA delete** on S3 for backups
7. **Use AWS WAF** on ALB for management UI

---

## Monitoring with CloudWatch

```bash
# Create CloudWatch alarm for queue depth
aws cloudwatch put-metric-alarm \
    --alarm-name rabbitmq-queue-depth-high \
    --metric-name QueueDepth \
    --namespace RabbitMQ \
    --statistic Average \
    --period 300 \
    --threshold 10000 \
    --comparison-operator GreaterThanThreshold \
    --evaluation-periods 2 \
    --alarm-actions arn:aws:sns:region:account:alert-topic
```

---

## Backup and Recovery

Consider using:
- **RabbitMQ definitions export** for configuration backup
- **EBS snapshots** for data backup
- **S3** for storing definition exports

```bash
# Export definitions
rabbitmqctl export_definitions /tmp/rabbitmq-definitions.json

# Import definitions
rabbitmqctl import_definitions /tmp/rabbitmq-definitions.json
```
