# AWS RDMA Complete Setup Guide

## Table of Contents
1. [Prerequisites](#prerequisites)
2. [Instance Setup](#instance-setup)
3. [RDMA Installation](#rdma-installation)
4. [Development Environment](#development-environment)
5. [SSH Configuration](#ssh-configuration)
6. [Project Organization](#project-organization)
7. [Testing and Validation](#testing-and-validation)
8. [Troubleshooting](#troubleshooting)

## Prerequisites

### Local Machine Requirements
- AWS CLI installed and configured
- SSH client
- Git
- Terminal with bash support

### AWS Requirements
- AWS account with EC2 access
- Ability to create security groups and key pairs
- Default VPC in chosen region

## Instance Setup

### 1. Launch Ubuntu Instance with RDMA Support

#### Option A: Ubuntu 20.04 (Recommended)
```bash
# Ubuntu 20.04 AMIs by region
us-east-1: ami-0c4f7023847b90238
us-west-2: ami-036d46416a34a611c
eu-west-1: ami-0a8e758f5e873d1c1
ap-southeast-1: ami-0d058fe428540cd89
```

#### Option B: Ubuntu 22.04
```bash
us-east-1: ami-0b529f3487c2c0e7f
us-west-2: ami-0895022f3dac85884
```

### 2. Instance Type Selection
```bash
# Recommended instance types for RDMA testing
t3.large   # 2 vCPU, 8GB RAM  - $0.0882/hour (cheapest)
t3.xlarge  # 4 vCPU, 16GB RAM - $0.1763/hour (better performance)
t3.2xlarge # 8 vCPU, 32GB RAM - $0.3526/hour (best performance)
```

### 3. Security Group Configuration
Required ports:
- 22 (SSH)
- 4433 (TLS server)
- 4791 (RDMA server)

## RDMA Installation

### Complete Installation Script
```bash
#!/bin/bash
# Save as: setup_rdma_environment.sh

set -e

echo "=== RDMA Environment Setup for AWS EC2 ==="
echo "This script will install all required components for RDMA development"
echo

# Update system
echo "1. Updating system packages..."
sudo apt-get update
sudo apt-get upgrade -y

# Install development tools
echo "2. Installing development tools..."
sudo apt-get install -y \
    build-essential \
    cmake \
    git \
    vim \
    htop \
    net-tools \
    pkg-config \
    python3-pip \
    gdb \
    valgrind

# Install SSL/TLS libraries
echo "3. Installing SSL/TLS libraries..."
sudo apt-get install -y \
    libssl-dev \
    openssl

# Install RDMA libraries and tools
echo "4. Installing RDMA stack..."
sudo apt-get install -y \
    rdma-core \
    libibverbs-dev \
    librdmacm-dev \
    ibverbs-utils \
    rdmacm-utils \
    perftest \
    infiniband-diags

# Install kernel with RDMA support (if needed)
echo "5. Installing HWE kernel for better RDMA support..."
sudo apt-get install -y linux-generic-hwe-20.04 || \
sudo apt-get install -y linux-generic-hwe-22.04

# Load RDMA kernel modules
echo "6. Loading RDMA kernel modules..."
sudo modprobe ib_core
sudo modprobe rdma_ucm
sudo modprobe rdma_rxe

# Setup Soft-RoCE
echo "7. Setting up Soft-RoCE..."
IFACE=$(ip route | grep default | awk '{print $5}')
sudo rdma link add rxe0 type rxe netdev $IFACE || echo "rxe0 already exists"

# Verify installation
echo "8. Verifying RDMA installation..."
ibv_devices
ibv_devinfo -d rxe0 | head -20

# Make modules persistent
echo "9. Making RDMA modules persistent..."
echo "ib_core" | sudo tee -a /etc/modules
echo "rdma_ucm" | sudo tee -a /etc/modules
echo "rdma_rxe" | sudo tee -a /etc/modules

# Create startup script
sudo tee /etc/systemd/system/rdma-setup.service << EOF
[Unit]
Description=Setup RDMA Soft-RoCE
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/rdma link add rxe0 type rxe netdev $IFACE
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl enable rdma-setup.service

echo
echo "=== RDMA Environment Setup Complete ==="
echo "RDMA device rxe0 is ready for use"
echo "You may need to reboot for all changes to take effect"
```

## Development Environment

### 1. Directory Structure
```bash
# Recommended project structure on instance
/home/ubuntu/
├── rdma-project/          # Main project directory
│   ├── src/              # Source code
│   │   ├── secure_rdma_server.c
│   │   ├── secure_rdma_client.c
│   │   ├── tls_utils.c
│   │   ├── tls_utils.h
│   │   └── rdma_compat.h
│   ├── docs/             # Documentation
│   │   ├── README.md
│   │   ├── requirements.md
│   │   └── architecture/
│   ├── scripts/          # Utility scripts
│   │   ├── test_rdma.sh
│   │   ├── benchmark.sh
│   │   └── monitor.sh
│   ├── tests/            # Test files
│   │   ├── unit/
│   │   └── integration/
│   ├── examples/         # Example code
│   ├── build/           # Build output
│   └── logs/            # Runtime logs
```

### 2. Development Tools Setup
```bash
# Install additional development tools
sudo apt-get install -y \
    tmux \
    neovim \
    clang \
    clang-format \
    clang-tidy \
    bear \
    universal-ctags

# Setup git
git config --global user.name "Your Name"
git config --global user.email "your.email@example.com"

# Install useful Python tools
pip3 install --user \
    ipython \
    jupyter \
    matplotlib \
    pandas \
    plotly
```

### 3. VS Code Remote Development (Optional)
```bash
# Install code-server for web-based VS Code
curl -fsSL https://code-server.dev/install.sh | sh
sudo systemctl enable --now code-server@ubuntu

# Configure code-server
mkdir -p ~/.config/code-server
cat > ~/.config/code-server/config.yaml << EOF
bind-addr: 0.0.0.0:8080
auth: password
password: your-secure-password
cert: false
EOF

sudo systemctl restart code-server@ubuntu
```

## SSH Configuration

### 1. Local SSH Config (~/.ssh/config)
```bash
# Add to your local ~/.ssh/config
Host rdma-aws
    HostName 18.236.198.30  # Replace with your instance IP
    User ubuntu
    Port 22
    IdentityFile ~/rdma-west-1754938408.pem  # Replace with your key path
    ServerAliveInterval 60
    ServerAliveCountMax 3
    TCPKeepAlive yes
    ForwardAgent yes
    
    # Optional: Forward ports for development
    LocalForward 8080 localhost:8080  # VS Code Server
    LocalForward 4433 localhost:4433  # TLS Server
    LocalForward 4791 localhost:4791  # RDMA Server

# Usage: ssh rdma-aws
```

### 2. SSH Key Management
```bash
# Set correct permissions
chmod 600 ~/rdma-west-1754938408.pem

# Add to ssh-agent for convenience
ssh-add ~/rdma-west-1754938408.pem

# Test connection
ssh rdma-aws "echo 'Connection successful'"
```

### 3. Persistent Sessions with tmux
```bash
# Create tmux configuration on instance
cat > ~/.tmux.conf << 'EOF'
# Enable mouse support
set -g mouse on

# Better colors
set -g default-terminal "screen-256color"

# Status bar
set -g status-bg black
set -g status-fg white
set -g status-left '#[fg=green]#H '
set -g status-right '#[fg=yellow]#(uptime | cut -d "," -f 1)'

# Start windows and panes at 1
set -g base-index 1
setw -g pane-base-index 1

# Reload config
bind r source-file ~/.tmux.conf \; display "Config reloaded!"
EOF

# Start development session
tmux new -s rdma-dev
```

## Project Organization

### 1. Makefile for Development
```makefile
# Enhanced Makefile with development targets
CC = gcc
CFLAGS = -Wall -Wextra -O2 -g -D_GNU_SOURCE -fsanitize=address
LDFLAGS = -lrdmacm -libverbs -lpthread -lssl -lcrypto -fsanitize=address

# Directories
SRC_DIR = src
BUILD_DIR = build
DOC_DIR = docs
TEST_DIR = tests

# Targets
.PHONY: all clean test docs install dev

all: secure_server secure_client

dev: CFLAGS += -DDEBUG -O0
dev: all

secure_server: $(SRC_DIR)/secure_rdma_server.c $(SRC_DIR)/tls_utils.c
	@mkdir -p $(BUILD_DIR)
	$(CC) $(CFLAGS) -I$(SRC_DIR) -o $(BUILD_DIR)/$@ $^ $(LDFLAGS)

secure_client: $(SRC_DIR)/secure_rdma_client.c $(SRC_DIR)/tls_utils.c
	@mkdir -p $(BUILD_DIR)
	$(CC) $(CFLAGS) -I$(SRC_DIR) -o $(BUILD_DIR)/$@ $^ $(LDFLAGS)

test:
	@echo "Running tests..."
	@./scripts/test_rdma.sh

benchmark:
	@echo "Running benchmarks..."
	@./scripts/benchmark.sh

docs:
	@echo "Generating documentation..."
	@doxygen Doxyfile 2>/dev/null || echo "Install doxygen for documentation"

install:
	@echo "Installing to /usr/local/bin..."
	@sudo cp $(BUILD_DIR)/secure_server /usr/local/bin/
	@sudo cp $(BUILD_DIR)/secure_client /usr/local/bin/

clean:
	rm -rf $(BUILD_DIR)/* *.o server.crt server.key

format:
	clang-format -i $(SRC_DIR)/*.c $(SRC_DIR)/*.h

check:
	cppcheck --enable=all $(SRC_DIR)
```

### 2. Testing Scripts
```bash
#!/bin/bash
# Save as: scripts/test_rdma.sh

set -e

echo "=== RDMA Test Suite ==="

# Check RDMA device
echo "1. Checking RDMA device..."
if ibv_devices | grep -q rxe0; then
    echo "   ✓ RDMA device found"
else
    echo "   ✗ RDMA device not found"
    exit 1
fi

# Build project
echo "2. Building project..."
make clean && make all
echo "   ✓ Build successful"

# Generate certificates
echo "3. Generating certificates..."
make generate-cert
echo "   ✓ Certificates created"

# Test server startup
echo "4. Testing server..."
timeout 5 ./build/secure_server > /tmp/server.log 2>&1 &
SERVER_PID=$!
sleep 2

if ps -p $SERVER_PID > /dev/null; then
    echo "   ✓ Server started"
    kill $SERVER_PID
else
    echo "   ✗ Server failed to start"
    cat /tmp/server.log
    exit 1
fi

# Test client connection
echo "5. Testing client connection..."
./build/secure_server > /tmp/server.log 2>&1 &
SERVER_PID=$!
sleep 2

if echo "quit" | timeout 5 ./build/secure_client 127.0.0.1 localhost > /tmp/client.log 2>&1; then
    echo "   ✓ Client connected successfully"
else
    echo "   ✗ Client connection failed"
    cat /tmp/client.log
fi

kill $SERVER_PID 2>/dev/null

echo
echo "=== Test Complete ==="
```

## Testing and Validation

### 1. RDMA Verification
```bash
# Verify RDMA is working
ibv_devices
ibv_devinfo -d rxe0
ibv_rc_pingpong &
ibv_rc_pingpong localhost
```

### 2. Performance Testing
```bash
# Bandwidth test
ib_send_bw -d rxe0 &
ib_send_bw -d rxe0 localhost

# Latency test
ib_send_lat -d rxe0 &
ib_send_lat -d rxe0 localhost

# RDMA write test
ib_write_bw -d rxe0 &
ib_write_bw -d rxe0 localhost
```

### 3. Security Validation
```bash
# Check TLS version
echo | openssl s_client -connect localhost:4433 2>/dev/null | grep TLS

# Verify certificate
openssl x509 -in server.crt -text -noout
```

## Troubleshooting

### Common Issues and Solutions

#### 1. RDMA Device Not Found
```bash
# Solution: Reload modules
sudo modprobe -r rdma_rxe
sudo modprobe rdma_rxe
sudo rdma link add rxe0 type rxe netdev $(ip route | grep default | awk '{print $5}')
```

#### 2. Permission Denied
```bash
# Solution: Add user to rdma group
sudo usermod -a -G rdma $USER
# Logout and login again
```

#### 3. Connection Timeout
```bash
# Check firewall rules
sudo iptables -L
# Check security group in AWS
aws ec2 describe-security-groups --group-ids <sg-id>
```

#### 4. Module Not Found
```bash
# Install correct kernel
sudo apt-get install linux-modules-extra-$(uname -r)
# Or install HWE kernel
sudo apt-get install linux-generic-hwe-20.04
sudo reboot
```

## Maintenance

### Regular Updates
```bash
# Update system
sudo apt-get update && sudo apt-get upgrade

# Update RDMA packages
sudo apt-get install --only-upgrade rdma-core libibverbs-dev librdmacm-dev

# Check RDMA status
rdma link show
ibv_devinfo
```

### Backup Important Files
```bash
# Backup script
tar -czf rdma-backup-$(date +%Y%m%d).tar.gz \
    ~/rdma-project \
    ~/.ssh/authorized_keys \
    ~/.tmux.conf \
    ~/.bashrc
```

## Quick Reference

### Essential Commands
```bash
# RDMA commands
ibv_devices              # List RDMA devices
ibv_devinfo -d rxe0      # Device information
rdma link show           # Show RDMA links
rdma resource show       # Show RDMA resources

# Project commands
make all                 # Build project
make test               # Run tests
make benchmark          # Run benchmarks
./build/secure_server   # Start server
./build/secure_client   # Start client

# Development
tmux new -s dev         # Start dev session
tmux attach -t dev      # Attach to session
git status              # Check git status
git log --oneline       # View commit history
```

## Next Steps

1. Clone your repository to the instance
2. Run the setup script
3. Configure SSH for easy access
4. Start development with tmux
5. Use VS Code Remote or code-server for IDE features

---

**Instance Details (Current)**
- IP: 18.236.198.30
- Region: us-west-2
- Instance ID: i-048b77cc8651ae684
- Key: rdma-west-1754938408.pem

**Remember**: Keep this instance running for development. Cost is only $0.09/hour.