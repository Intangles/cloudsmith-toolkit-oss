#!/bin/bash
#
# MongoDB 5.x Installation Script for AWS Linux Graviton (ARM64)
# This script installs MongoDB 5.0 on Amazon Linux 2 running on Graviton instances
# STATUS: VERIFIED THE INSTALLATION ON AWS GRAVITON2 INSTANCE
#

set -e

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

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root (use sudo)"
    exit 1
fi

# Check architecture
ARCH=$(uname -m)
if [[ "$ARCH" != "aarch64" ]]; then
    log_error "This script is designed for ARM64 (Graviton) instances. Detected: $ARCH"
    exit 1
fi

log_info "Detected ARM64 architecture - Graviton instance confirmed"

# Detect OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    VERSION_ID=$VERSION_ID
else
    log_error "Cannot detect OS version"
    exit 1
fi

log_info "Detected OS: $OS $VERSION_ID"

# MongoDB version
MONGODB_VERSION="5.0"

# External volume configuration
EBS_DEVICE="/dev/nvme1n1"
DATA_DIR="/data"
MONGODB_PORT="12345"
KEYFILE_PATH="/opt/mongo-key"
REPLICA_SET_NAME="rs0"

# Mount external EBS volume
mount_ebs_volume() {
    log_info "Setting up external EBS volume..."
    
    # Check if device exists
    if [ ! -b "$EBS_DEVICE" ]; then
        log_error "Device $EBS_DEVICE not found. Please attach the EBS volume first."
        exit 1
    fi
    
    # Create data directory if not exists
    if [ ! -d "$DATA_DIR" ]; then
        log_info "Creating $DATA_DIR directory..."
        mkdir -p "$DATA_DIR"
    fi
    
    # Check if already mounted
    if mount | grep -q "$DATA_DIR"; then
        log_info "$DATA_DIR is already mounted"
        return 0
    fi
    
    # Check if device has a filesystem
    FSTYPE=$(blkid -o value -s TYPE "$EBS_DEVICE" 2>/dev/null || echo "")
    
    if [ -z "$FSTYPE" ]; then
        log_info "No filesystem found on $EBS_DEVICE. Formatting as XFS..."
        
        # Install xfsprogs if not present
        if ! command -v mkfs.xfs &> /dev/null; then
            log_info "Installing xfsprogs..."
            yum install -y xfsprogs
        fi
        
        # Format as XFS
        mkfs.xfs -f "$EBS_DEVICE"
        
        if [ $? -eq 0 ]; then
            log_info "Successfully formatted $EBS_DEVICE as XFS"
        else
            log_error "Failed to format $EBS_DEVICE"
            exit 1
        fi
    elif [ "$FSTYPE" != "xfs" ]; then
        log_warn "Device $EBS_DEVICE has $FSTYPE filesystem. Expected XFS."
        log_warn "To reformat, manually run: mkfs.xfs -f $EBS_DEVICE"
    else
        log_info "Device $EBS_DEVICE already has XFS filesystem"
    fi
    
    # Mount the volume
    log_info "Mounting $EBS_DEVICE to $DATA_DIR..."
    mount "$EBS_DEVICE" "$DATA_DIR"
    
    if [ $? -eq 0 ]; then
        log_info "Successfully mounted $EBS_DEVICE to $DATA_DIR"
    else
        log_error "Failed to mount $EBS_DEVICE"
        exit 1
    fi
    
    # Get UUID for fstab entry
    UUID=$(blkid -o value -s UUID "$EBS_DEVICE")
    
    # Add to fstab for persistence across reboots
    if ! grep -q "$UUID" /etc/fstab; then
        log_info "Adding $DATA_DIR to /etc/fstab for persistence..."
        echo "UUID=$UUID  $DATA_DIR  xfs  defaults,nofail  0  2" >> /etc/fstab
        log_info "Added fstab entry: UUID=$UUID  $DATA_DIR  xfs  defaults,nofail  0  2"
    else
        log_info "fstab entry already exists for $EBS_DEVICE"
    fi
    
    # Create MongoDB data subdirectory
    mkdir -p "$DATA_DIR/mongodb"
    mkdir -p "$DATA_DIR/mongodb/log"
    
    log_info "EBS volume setup complete"
}

# Create MongoDB repository file
create_repo_amazon_linux_2() {
    log_info "Creating MongoDB $MONGODB_VERSION repository for Amazon Linux 2..."
    
    cat > /etc/yum.repos.d/mongodb-org-${MONGODB_VERSION}.repo << EOF
[mongodb-org-${MONGODB_VERSION}]
name=MongoDB Repository
baseurl=https://repo.mongodb.org/yum/amazon/2/mongodb-org/${MONGODB_VERSION}/aarch64/
gpgcheck=1
enabled=1
gpgkey=https://www.mongodb.org/static/pgp/server-${MONGODB_VERSION}.asc
EOF
}

create_repo_amazon_linux_2023() {
    log_info "Creating MongoDB $MONGODB_VERSION repository for Amazon Linux 2023..."
    
    cat > /etc/yum.repos.d/mongodb-org-${MONGODB_VERSION}.repo << EOF
[mongodb-org-${MONGODB_VERSION}]
name=MongoDB Repository
baseurl=https://repo.mongodb.org/yum/amazon/2023/mongodb-org/${MONGODB_VERSION}/aarch64/
gpgcheck=1
enabled=1
gpgkey=https://www.mongodb.org/static/pgp/server-${MONGODB_VERSION}.asc
EOF
}

# Install MongoDB
install_mongodb() {
    log_info "Installing MongoDB $MONGODB_VERSION..."
    
    # Clean yum cache
    yum clean all
    
    # Install MongoDB packages
    yum install -y mongodb-org
    
    if [ $? -eq 0 ]; then
        log_info "MongoDB $MONGODB_VERSION installed successfully"
    else
        log_error "Failed to install MongoDB"
        exit 1
    fi

    sudo chown -R mongod:mongod "$DATA_DIR"
    sudo chown -R mongod:mongod "$KEYFILE_PATH"
    sudo chmod 400 "$KEYFILE_PATH"
}

# Configure MongoDB
configure_mongodb() {
    log_info "Configuring MongoDB..."
    
    # Backup original config
    if [ -f /etc/mongod.conf ]; then
        cp /etc/mongod.conf /etc/mongod.conf.backup
        log_info "Original config backed up to /etc/mongod.conf.backup"
    fi
    
    # Use external volume for data and logs
    MONGO_DATA_DIR="$DATA_DIR/mongodb"
    MONGO_LOG_DIR="$DATA_DIR/mongodb/log"
    
    # Create data and log directories if they don't exist
    mkdir -p "$MONGO_DATA_DIR"
    mkdir -p "$MONGO_LOG_DIR"
    
    # Set proper ownership
    chown -R mongod:mongod "$MONGO_DATA_DIR"
    chown -R mongod:mongod "$MONGO_LOG_DIR"
    
    # Set proper permissions
    chmod 755 "$MONGO_DATA_DIR"
    chmod 755 "$MONGO_LOG_DIR"
    
    # Update mongod.conf to use external volume paths
    log_info "Updating MongoDB configuration to use $DATA_DIR..."
    
    cat > /etc/mongod.conf << EOF
# mongod.conf - MongoDB configuration file

# Where and how to store data
storage:
  dbPath: $MONGO_DATA_DIR
  journal:
    enabled: true

# Where to write logging data
systemLog:
  destination: file
  logAppend: true
  path: $MONGO_LOG_DIR/mongod.log

# Network interfaces
net:
  port: $MONGODB_PORT
  bindIp: 0.0.0.0

# Process management
processManagement:
  timeZoneInfo: /usr/share/zoneinfo

security:
  keyFile: $KEYFILE_PATH

replication:
  replSetName: $REPLICA_SET_NAME
EOF
    
    log_info "MongoDB configured to use $MONGO_DATA_DIR for data and $MONGO_LOG_DIR for logs"
}

# Configure system limits
configure_system_limits() {
    log_info "Configuring system limits for MongoDB..."
    
    # Create limits file for mongod
    cat > /etc/security/limits.d/99-mongodb.conf << EOF
mongod soft nofile 64000
mongod hard nofile 64000
mongod soft nproc 64000
mongod hard nproc 64000
EOF

    # Disable Transparent Huge Pages (THP) - recommended for MongoDB
    if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
        echo never > /sys/kernel/mm/transparent_hugepage/enabled
        echo never > /sys/kernel/mm/transparent_hugepage/defrag
    fi
    
    # Create systemd service to disable THP on boot
    cat > /etc/systemd/system/disable-thp.service << EOF
[Unit]
Description=Disable Transparent Huge Pages (THP)
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=mongod.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never | tee /sys/kernel/mm/transparent_hugepage/enabled > /dev/null'
ExecStart=/bin/sh -c 'echo never | tee /sys/kernel/mm/transparent_hugepage/defrag > /dev/null'

[Install]
WantedBy=basic.target
EOF

    systemctl daemon-reload
    systemctl enable disable-thp
    
    log_info "System limits configured"
}

# Start MongoDB service
start_mongodb() {
    log_info "Starting MongoDB service..."
    
    # Enable MongoDB to start on boot
    systemctl enable mongod
    
    # Start MongoDB
    systemctl start mongod
    
    # Check status
    if systemctl is-active --quiet mongod; then
        log_info "MongoDB is running"
    else
        log_error "MongoDB failed to start. Check logs: journalctl -u mongod"
        exit 1
    fi
}

# Verify installation
verify_installation() {
    log_info "Verifying MongoDB installation..."
    
    # Wait for MongoDB to be ready
    sleep 3
    
    # Check MongoDB version
    mongod --version
    
    # Try to connect
    if command -v mongosh &> /dev/null; then
        mongosh --port $MONGODB_PORT --eval "db.adminCommand('ping')" --quiet
    elif command -v mongo &> /dev/null; then
        mongo --port $MONGODB_PORT --eval "db.adminCommand('ping')" --quiet
    fi
    
    if [ $? -eq 0 ]; then
        log_info "MongoDB is responding to connections"
    else
        log_warn "MongoDB may not be ready yet. Check: systemctl status mongod"
    fi
}

# Print post-installation info
print_info() {
    echo ""
    echo "=========================================="
    echo -e "${GREEN}MongoDB $MONGODB_VERSION Installation Complete${NC}"
    echo "=========================================="
    echo ""
    echo "Useful commands:"
    echo "  - Start MongoDB:   sudo systemctl start mongod"
    echo "  - Stop MongoDB:    sudo systemctl stop mongod"
    echo "  - Restart MongoDB: sudo systemctl restart mongod"
    echo "  - Check status:    sudo systemctl status mongod"
    echo "  - View logs:       sudo tail -f $DATA_DIR/mongodb/log/mongod.log"
    echo "  - Connect:         mongosh"
    echo ""
    echo "Configuration file: /etc/mongod.conf"
    echo "Data directory:     $DATA_DIR/mongodb"
    echo "Log directory:      $DATA_DIR/mongodb/log"
    echo ""
    echo -e "${YELLOW}IMPORTANT:${NC} For production use, configure:"
    echo "  - Authentication (security.authorization: enabled)"
    echo "  - Bind IP address (net.bindIp)"
    echo "  - Replica set (if required)"
    echo ""
}

# Main installation flow
main() {
    log_info "Starting MongoDB $MONGODB_VERSION installation on Graviton instance..."
    
    # Create repository based on OS
    case "$OS" in
        amzn)
            if [[ "$VERSION_ID" == "2" ]]; then
                create_repo_amazon_linux_2
            elif [[ "$VERSION_ID" == "2023" ]]; then
                create_repo_amazon_linux_2023
            else
                log_error "Unsupported Amazon Linux version: $VERSION_ID"
                exit 1
            fi
            ;;
        *)
            log_error "Unsupported OS: $OS. This script supports Amazon Linux 2 and 2023."
            exit 1
            ;;
    esac
    
    mount_ebs_volume
    install_mongodb
    configure_mongodb
    configure_system_limits
    start_mongodb
    verify_installation
    print_info
    
    log_info "Installation completed successfully!"
}

# Run main function
main
