#!/bin/bash

# AWS Quick Setup Script for RDMA with Soft-RoCE
# IMPORTANT: Requires Ubuntu 20.04 with HWE kernel (5.15.0 or newer)
# Ubuntu 22.04 may have kernel module issues!

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  AWS RDMA Soft-RoCE Quick Setup${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# System verification
echo -e "${BLUE}=== System Verification ===${NC}"
echo -e "${YELLOW}OS Version:${NC}"
lsb_release -a 2>/dev/null || cat /etc/os-release

echo -e "\n${YELLOW}Kernel Version:${NC}"
uname -r

# Check if we have the right kernel
KERNEL_VERSION=$(uname -r)
if [[ ! "$KERNEL_VERSION" =~ 5\.15\.|5\.1[6-9]\.|6\. ]]; then
    echo -e "${RED}WARNING: Kernel version $KERNEL_VERSION may not support rdma_rxe module!${NC}"
    echo -e "${YELLOW}Ubuntu 20.04 requires HWE kernel (5.15.0 or newer)${NC}"
    echo -e "${YELLOW}To install HWE kernel, run:${NC}"
    echo "  sudo apt-get install -y linux-generic-hwe-20.04"
    echo "  sudo reboot"
    echo ""
    read -p "Continue anyway? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Check for rdma_rxe module availability
echo -e "\n${YELLOW}Checking for rdma_rxe module availability...${NC}"
if modinfo rdma_rxe &>/dev/null; then
    echo -e "${GREEN}✓ rdma_rxe module is available${NC}"
else
    echo -e "${RED}✗ rdma_rxe module not found!${NC}"
    echo -e "${YELLOW}This kernel doesn't support Soft-RoCE.${NC}"
    if grep -q "Ubuntu 20.04" /etc/os-release; then
        echo -e "${YELLOW}Installing HWE kernel...${NC}"
        sudo apt-get update
        sudo apt-get install -y linux-generic-hwe-20.04
        echo -e "${GREEN}HWE kernel installed. Please reboot and run this script again.${NC}"
        exit 0
    else
        echo -e "${RED}Please use Ubuntu 20.04 LTS with HWE kernel.${NC}"
        exit 1
    fi
fi

# Detect network interface
INTERFACE=$(ip route | grep default | awk '{print $5}' | head -1)
echo -e "\n${YELLOW}Detected network interface: $INTERFACE${NC}"

# Step 1: Update system
echo -e "\n${YELLOW}Step 1: Updating system packages...${NC}"
sudo apt-get update
sudo apt-get upgrade -y

# Step 2: Install dependencies
echo -e "\n${YELLOW}Step 2: Installing RDMA dependencies...${NC}"
sudo apt-get install -y \
    build-essential \
    git \
    libibverbs-dev \
    librdmacm-dev \
    rdma-core \
    ibverbs-utils \
    rdmacm-utils \
    perftest \
    infiniband-diags \
    libssl-dev \
    openssl

# Step 3: Load kernel modules
echo -e "\n${YELLOW}Step 3: Loading RDMA kernel modules...${NC}"
sudo modprobe rdma_rxe
sudo modprobe ib_core
sudo modprobe rdma_ucm

# Verify modules
if lsmod | grep -q rdma_rxe; then
    echo -e "${GREEN}✓ RDMA modules loaded successfully${NC}"
else
    echo -e "${RED}✗ Failed to load RDMA modules${NC}"
    exit 1
fi

# Step 4: Configure Soft-RoCE
echo -e "\n${YELLOW}Step 4: Configuring Soft-RoCE device...${NC}"

# Remove existing rxe0 if it exists
sudo rdma link delete rxe0 2>/dev/null || true

# Add new rxe device
sudo rdma link add rxe0 type rxe netdev $INTERFACE

# Verify device created
if ibv_devices | grep -q rxe0; then
    echo -e "${GREEN}✓ Soft-RoCE device created successfully${NC}"
    ibv_devices
else
    echo -e "${RED}✗ Failed to create Soft-RoCE device${NC}"
    exit 1
fi

# Step 5: Clone and build project
echo -e "\n${YELLOW}Step 5: Cloning and building RDMA project...${NC}"

# Check if already cloned
if [ ! -d "$HOME/rdma-multi-client" ]; then
    cd $HOME
    git clone https://github.com/linjiw/rdma-multi-client.git
fi

cd $HOME/rdma-multi-client

# Build project
make clean && make all

# Generate certificates
make generate-cert

# Verify build
if [ -f "build/secure_server" ] && [ -f "build/secure_client" ]; then
    echo -e "${GREEN}✓ Project built successfully${NC}"
else
    echo -e "${RED}✗ Build failed${NC}"
    exit 1
fi

# Step 6: Create systemd service for persistence (optional)
echo -e "\n${YELLOW}Step 6: Creating systemd service for Soft-RoCE persistence...${NC}"

sudo tee /etc/systemd/system/soft-roce.service > /dev/null << EOF
[Unit]
Description=Configure Soft-RoCE
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/bin/rdma link add rxe0 type rxe netdev $INTERFACE
RemainAfterExit=yes
StandardOutput=journal

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable soft-roce.service
echo -e "${GREEN}✓ Systemd service created${NC}"

# Step 7: Display information
echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}  Setup Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}System Information:${NC}"
echo "  • Instance Type: $(ec2-metadata --instance-type 2>/dev/null | cut -d' ' -f2 || echo 'Unknown')"
echo "  • Private IP: $(hostname -I | awk '{print $1}')"
echo "  • Network Interface: $INTERFACE"
echo "  • RDMA Device: rxe0"
echo ""
echo -e "${YELLOW}Project Location:${NC}"
echo "  $HOME/rdma-multi-client"
echo ""
echo -e "${YELLOW}To run the demo:${NC}"
echo "  cd $HOME/rdma-multi-client"
echo "  ./run_demo_auto.sh"
echo ""
echo -e "${YELLOW}To start server:${NC}"
echo "  cd $HOME/rdma-multi-client"
echo "  ./build/secure_server"
echo ""
echo -e "${YELLOW}To connect client:${NC}"
echo "  cd $HOME/rdma-multi-client"
echo "  ./build/secure_client 127.0.0.1 localhost"
echo ""
echo -e "${GREEN}Setup script completed successfully!${NC}"