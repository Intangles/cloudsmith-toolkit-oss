#!/bin/bash
#===============================================================================
# RabbitMQ 3.8.3-rc.2 with Erlang 22.3.4.1 Installation Script
# For Amazon Linux 2 on AWS Graviton (ARM64/aarch64)
#===============================================================================
# 
# This script installs RabbitMQ server with clustering support for AWS ASG
# 
# Usage: sudo ./graviton.sh
#
# # STATUS: YET TO VERIFY THE INSTALLATION ON AWS GRAVITON2 INSTANCE
#===============================================================================

set -e

# Configuration
ERLANG_VERSION="22.3.4.1"
RABBITMQ_VERSION="3.8.3-rc.2"
RABBITMQ_USER="rabbitmq"
RABBITMQ_CLUSTER_NAME="rabbit-cluster"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

#===============================================================================
# STEP 1: System Prerequisites
#===============================================================================
install_prerequisites() {
    log_info "Installing system prerequisites..."
    
    # Update system
    sudo yum update -y
    
    # Install required packages
    sudo yum install -y \
        wget \
        curl \
        git \
        gcc \
        gcc-c++ \
        make \
        ncurses-devel \
        openssl-devel \
        unixODBC-devel \
        java-11-amazon-corretto-headless \
        socat \
        logrotate \
        systemd \
        hostname \
        jq \
        awscli
    
    log_info "Prerequisites installed successfully"
}

#===============================================================================
# STEP 2: Install Erlang 22.3.4.1 from source (ARM64 compatible)
#===============================================================================
install_erlang() {
    log_info "Installing Erlang ${ERLANG_VERSION} from source..."
    
    cd /tmp
    
    # Download Erlang source
    wget https://github.com/erlang/otp/releases/download/OTP-${ERLANG_VERSION}/otp_src_${ERLANG_VERSION}.tar.gz
    
    # Extract and compile
    tar -xzf otp_src_${ERLANG_VERSION}.tar.gz
    cd otp_src_${ERLANG_VERSION}
    
    # Configure for ARM64
    export ERL_TOP=$(pwd)
    ./configure \
        --prefix=/usr/local \
        --enable-threads \
        --enable-smp-support \
        --enable-kernel-poll \
        --enable-hipe \
        --with-ssl \
        --without-javac
    
    # Compile with available CPU cores
    make -j$(nproc)
    sudo make install
    
    # Verify installation
    /usr/local/bin/erl -version
    
    # Add to PATH
    echo 'export PATH=/usr/local/bin:$PATH' | sudo tee /etc/profile.d/erlang.sh
    source /etc/profile.d/erlang.sh
    
    log_info "Erlang ${ERLANG_VERSION} installed successfully"
    
    # Cleanup
    cd /tmp
    rm -rf otp_src_${ERLANG_VERSION} otp_src_${ERLANG_VERSION}.tar.gz
}

#===============================================================================
# STEP 3: Install RabbitMQ 3.8.3-rc.2
#===============================================================================
install_rabbitmq() {
    log_info "Installing RabbitMQ ${RABBITMQ_VERSION}..."
    
    cd /tmp
    
    # Create rabbitmq user and group
    sudo groupadd -r rabbitmq 2>/dev/null || true
    sudo useradd -r -g rabbitmq -d /var/lib/rabbitmq -s /sbin/nologin rabbitmq 2>/dev/null || true
    
    # Download RabbitMQ generic unix package
    wget https://github.com/rabbitmq/rabbitmq-server/releases/download/v${RABBITMQ_VERSION}/rabbitmq-server-generic-unix-${RABBITMQ_VERSION}.tar.xz
    
    # Extract to /opt
    sudo mkdir -p /opt/rabbitmq
    sudo tar -xJf rabbitmq-server-generic-unix-${RABBITMQ_VERSION}.tar.xz -C /opt/rabbitmq --strip-components=1
    
    # Create required directories
    sudo mkdir -p /var/lib/rabbitmq
    sudo mkdir -p /var/log/rabbitmq
    sudo mkdir -p /etc/rabbitmq
    
    # Set ownership
    sudo chown -R rabbitmq:rabbitmq /opt/rabbitmq
    sudo chown -R rabbitmq:rabbitmq /var/lib/rabbitmq
    sudo chown -R rabbitmq:rabbitmq /var/log/rabbitmq
    sudo chown -R rabbitmq:rabbitmq /etc/rabbitmq
    
    # Create symlinks for binaries
    sudo ln -sf /opt/rabbitmq/sbin/rabbitmq-server /usr/local/bin/rabbitmq-server
    sudo ln -sf /opt/rabbitmq/sbin/rabbitmqctl /usr/local/bin/rabbitmqctl
    sudo ln -sf /opt/rabbitmq/sbin/rabbitmq-plugins /usr/local/bin/rabbitmq-plugins
    sudo ln -sf /opt/rabbitmq/sbin/rabbitmq-diagnostics /usr/local/bin/rabbitmq-diagnostics
    
    log_info "RabbitMQ ${RABBITMQ_VERSION} installed successfully"
    
    # Cleanup
    rm -f rabbitmq-server-generic-unix-${RABBITMQ_VERSION}.tar.xz
}

#===============================================================================
# STEP 4: Configure RabbitMQ Environment
#===============================================================================
configure_rabbitmq_env() {
    log_info "Configuring RabbitMQ environment..."
    
    # Get instance metadata
    INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
    PRIVATE_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
    HOSTNAME=$(hostname -s)
    
    # Create rabbitmq-env.conf
    sudo tee /etc/rabbitmq/rabbitmq-env.conf > /dev/null << 'EOF'
# RabbitMQ Environment Configuration
RABBITMQ_NODENAME=rabbit@$(hostname -s)
RABBITMQ_CONFIG_FILE=/etc/rabbitmq/rabbitmq
RABBITMQ_LOG_BASE=/var/log/rabbitmq
RABBITMQ_MNESIA_BASE=/var/lib/rabbitmq/mnesia
RABBITMQ_PID_FILE=/var/run/rabbitmq/pid
RABBITMQ_USE_LONGNAME=false

# Erlang VM settings
export ERL_EPMD_ADDRESS=0.0.0.0
export RABBITMQ_SERVER_START_ARGS="-kernel inet_dist_listen_min 25672 inet_dist_listen_max 25672"
EOF

    # Create advanced rabbitmq.conf
    sudo tee /etc/rabbitmq/rabbitmq.conf > /dev/null << 'EOF'
# =======================================================
# RabbitMQ Configuration for AWS Graviton Cluster
# =======================================================

# Networking
listeners.tcp.default = 5672
management.tcp.port = 15672

# Clustering
cluster_formation.peer_discovery_backend = aws
cluster_formation.aws.region = us-east-1
cluster_formation.aws.use_autoscaling_group = true
cluster_formation.aws.use_private_ip = true

# Node discovery interval
cluster_formation.node_cleanup.interval = 30
cluster_formation.node_cleanup.only_log_warning = true

# Memory and disk thresholds
vm_memory_high_watermark.relative = 0.7
disk_free_limit.absolute = 5GB

# Logging
log.file.level = info
log.console = true
log.console.level = info

# Connection settings
heartbeat = 60
channel_max = 2047

# Queue settings
queue_master_locator = min-masters

# SSL/TLS (uncomment and configure if needed)
# ssl_options.cacertfile = /path/to/ca_certificate.pem
# ssl_options.certfile   = /path/to/server_certificate.pem
# ssl_options.keyfile    = /path/to/server_key.pem
# ssl_options.verify     = verify_peer
# ssl_options.fail_if_no_peer_cert = false
EOF

    # Create PID directory
    sudo mkdir -p /var/run/rabbitmq
    sudo chown rabbitmq:rabbitmq /var/run/rabbitmq
    
    log_info "RabbitMQ environment configured"
}

#===============================================================================
# STEP 5: Generate Erlang Cookie for Clustering
#===============================================================================
setup_erlang_cookie() {
    log_info "Setting up Erlang cookie for clustering..."
    
    # The cookie should be the same across all cluster nodes
    # In production, fetch this from AWS Secrets Manager or Parameter Store
    
    # Example: Fetch from AWS SSM Parameter Store
    # ERLANG_COOKIE=$(aws ssm get-parameter --name "/rabbitmq/erlang-cookie" --with-decryption --query "Parameter.Value" --output text)
    
    # For demo purposes, generate a random cookie (replace in production)
    ERLANG_COOKIE="RABBITMQ_CLUSTER_SECRET_COOKIE_CHANGE_ME"
    
    # Create cookie file
    echo -n "$ERLANG_COOKIE" | sudo tee /var/lib/rabbitmq/.erlang.cookie > /dev/null
    sudo chmod 400 /var/lib/rabbitmq/.erlang.cookie
    sudo chown rabbitmq:rabbitmq /var/lib/rabbitmq/.erlang.cookie
    
    log_info "Erlang cookie configured"
}

#===============================================================================
# STEP 6: Create Systemd Service
#===============================================================================
create_systemd_service() {
    log_info "Creating systemd service..."
    
    sudo tee /etc/systemd/system/rabbitmq-server.service > /dev/null << 'EOF'
[Unit]
Description=RabbitMQ broker
After=network.target epmd@0.0.0.0.socket
Wants=network.target epmd@0.0.0.0.socket

[Service]
Type=notify
User=rabbitmq
Group=rabbitmq
NotifyAccess=all
TimeoutStartSec=3600
WorkingDirectory=/var/lib/rabbitmq
RuntimeDirectory=rabbitmq
RuntimeDirectoryMode=0755

# Environment
Environment="RABBITMQ_HOME=/opt/rabbitmq"
Environment="HOME=/var/lib/rabbitmq"
Environment="PATH=/usr/local/bin:/opt/rabbitmq/sbin:/usr/bin:/bin"

ExecStart=/opt/rabbitmq/sbin/rabbitmq-server
ExecStop=/opt/rabbitmq/sbin/rabbitmqctl shutdown
ExecReload=/bin/kill -HUP $MAINPID

Restart=on-failure
RestartSec=10

# Resource limits
LimitNOFILE=65536
LimitNPROC=65536

[Install]
WantedBy=multi-user.target
EOF

    # Create EPMD socket service
    sudo tee /etc/systemd/system/epmd@.socket > /dev/null << 'EOF'
[Unit]
Description=Erlang Port Mapper Daemon Activation Socket

[Socket]
ListenStream=%i:4369
Accept=false

[Install]
WantedBy=sockets.target
EOF

    sudo tee /etc/systemd/system/epmd@.service > /dev/null << 'EOF'
[Unit]
Description=Erlang Port Mapper Daemon
After=network.target
Requires=epmd@%i.socket

[Service]
ExecStart=/usr/local/bin/epmd -address %i
Type=simple
StandardOutput=journal
StandardError=journal
User=rabbitmq
Group=rabbitmq
EOF

    # Reload systemd
    sudo systemctl daemon-reload
    
    # Enable services
    sudo systemctl enable epmd@0.0.0.0.socket
    sudo systemctl enable rabbitmq-server
    
    log_info "Systemd services created and enabled"
}

#===============================================================================
# STEP 7: Enable RabbitMQ Plugins
#===============================================================================
enable_plugins() {
    log_info "Enabling RabbitMQ plugins..."
    
    # Create enabled_plugins file
    sudo tee /etc/rabbitmq/enabled_plugins > /dev/null << 'EOF'
[rabbitmq_management,rabbitmq_management_agent,rabbitmq_peer_discovery_aws,rabbitmq_prometheus,rabbitmq_shovel,rabbitmq_shovel_management].
EOF
    
    sudo chown rabbitmq:rabbitmq /etc/rabbitmq/enabled_plugins
    
    log_info "Plugins enabled"
}

#===============================================================================
# STEP 8: Configure OS Limits
#===============================================================================
configure_os_limits() {
    log_info "Configuring OS limits..."
    
    # Set file descriptor limits
    sudo tee /etc/security/limits.d/rabbitmq.conf > /dev/null << 'EOF'
rabbitmq soft nofile 65536
rabbitmq hard nofile 65536
rabbitmq soft nproc 65536
rabbitmq hard nproc 65536
EOF

    # Kernel parameters
    sudo tee /etc/sysctl.d/99-rabbitmq.conf > /dev/null << 'EOF'
# RabbitMQ optimizations
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
vm.swappiness = 1
EOF

    sudo sysctl -p /etc/sysctl.d/99-rabbitmq.conf
    
    log_info "OS limits configured"
}

#===============================================================================
# STEP 9: Cluster Join Script (for ASG instances)
#===============================================================================
create_cluster_join_script() {
    log_info "Creating cluster join script..."
    
    sudo tee /opt/rabbitmq/join-cluster.sh > /dev/null << 'SCRIPT'
#!/bin/bash
# RabbitMQ Cluster Join Script for AWS ASG
# This script runs on instance startup to join the cluster

set -e

REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
ASG_NAME=$(aws autoscaling describe-auto-scaling-instances \
    --instance-ids $(curl -s http://169.254.169.254/latest/meta-data/instance-id) \
    --region $REGION \
    --query 'AutoScalingInstances[0].AutoScalingGroupName' \
    --output text)

# Get all instances in ASG
INSTANCES=$(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names $ASG_NAME \
    --region $REGION \
    --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`].InstanceId' \
    --output text)

# Get private IPs
for INSTANCE in $INSTANCES; do
    IP=$(aws ec2 describe-instances \
        --instance-ids $INSTANCE \
        --region $REGION \
        --query 'Reservations[0].Instances[0].PrivateIpAddress' \
        --output text)
    
    HOSTNAME=$(aws ec2 describe-instances \
        --instance-ids $INSTANCE \
        --region $REGION \
        --query 'Reservations[0].Instances[0].PrivateDnsName' \
        --output text | cut -d'.' -f1)
    
    # Add to /etc/hosts
    grep -q "$IP" /etc/hosts || echo "$IP $HOSTNAME" >> /etc/hosts
done

# Wait for RabbitMQ to start
sleep 30

# Get the first running node to join
MY_HOSTNAME=$(hostname -s)
MY_NODE="rabbit@${MY_HOSTNAME}"

for INSTANCE in $INSTANCES; do
    REMOTE_HOSTNAME=$(aws ec2 describe-instances \
        --instance-ids $INSTANCE \
        --region $REGION \
        --query 'Reservations[0].Instances[0].PrivateDnsName' \
        --output text | cut -d'.' -f1)
    
    REMOTE_NODE="rabbit@${REMOTE_HOSTNAME}"
    
    if [ "$MY_NODE" != "$REMOTE_NODE" ]; then
        # Check if remote node is running
        if rabbitmqctl -n $REMOTE_NODE status &>/dev/null; then
            echo "Joining cluster via $REMOTE_NODE"
            rabbitmqctl stop_app
            rabbitmqctl reset
            rabbitmqctl join_cluster $REMOTE_NODE
            rabbitmqctl start_app
            echo "Successfully joined cluster"
            exit 0
        fi
    fi
done

echo "No existing cluster found, starting as standalone node"
SCRIPT

    sudo chmod +x /opt/rabbitmq/join-cluster.sh
    sudo chown rabbitmq:rabbitmq /opt/rabbitmq/join-cluster.sh
    
    log_info "Cluster join script created"
}

#===============================================================================
# STEP 10: Create Default Admin User
#===============================================================================
create_admin_user() {
    log_info "Creating admin user..."
    
    # Wait for RabbitMQ to be ready
    sleep 10
    
    # Create admin user
    rabbitmqctl add_user admin "$(openssl rand -base64 24)" || true
    rabbitmqctl set_user_tags admin administrator
    rabbitmqctl set_permissions -p / admin ".*" ".*" ".*"
    
    # Remove guest user for security
    rabbitmqctl delete_user guest || true
    
    log_info "Admin user created"
}

#===============================================================================
# STEP 11: Health Check Script
#===============================================================================
create_health_check() {
    log_info "Creating health check script..."
    
    sudo tee /opt/rabbitmq/health-check.sh > /dev/null << 'SCRIPT'
#!/bin/bash
# RabbitMQ Health Check Script for AWS Target Group

set -e

# Check if RabbitMQ is running
if ! rabbitmqctl status &>/dev/null; then
    echo "RabbitMQ is not running"
    exit 1
fi

# Check if the node is part of a cluster and healthy
if ! rabbitmqctl cluster_status &>/dev/null; then
    echo "Cluster status check failed"
    exit 1
fi

# Check management API
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:15672/api/healthchecks/node)
if [ "$HTTP_CODE" != "200" ]; then
    echo "Management API health check failed"
    exit 1
fi

echo "RabbitMQ is healthy"
exit 0
SCRIPT

    sudo chmod +x /opt/rabbitmq/health-check.sh
    
    log_info "Health check script created"
}

#===============================================================================
# Main Installation Flow
#===============================================================================
main() {
    log_info "Starting RabbitMQ installation on Graviton..."
    
    install_prerequisites
    install_erlang
    install_rabbitmq
    configure_rabbitmq_env
    setup_erlang_cookie
    create_systemd_service
    enable_plugins
    configure_os_limits
    create_cluster_join_script
    create_health_check
    
    # Start RabbitMQ
    log_info "Starting RabbitMQ server..."
    sudo systemctl start rabbitmq-server
    
    # Wait for startup
    sleep 10
    
    # Verify installation
    rabbitmqctl status
    
    log_info "RabbitMQ ${RABBITMQ_VERSION} installation completed!"
    log_info "Management UI: http://$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4):15672"
}

# Run main function
main "$@"
