#!/bin/bash

# AWS EC2 Deployment Script for Secure RDMA Testing with Soft-RoCE
# This script launches a t3.large instance with Soft-RoCE for cost-effective RDMA testing
# Cost: ~$0.09/hour instead of $20+/hour for EFA instances

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.large}"  # Can override with t3.xlarge
REGION="${AWS_REGION:-us-east-1}"
AMI_ID=""  # Will be auto-detected for Ubuntu 22.04
KEY_NAME="rdma-test-key-$(date +%s)"
SECURITY_GROUP="rdma-test-sg-$(date +%s)"
INSTANCE_NAME="rdma-softrce-test"
PROJECT_DIR="rdma-project"

# Files to track resources for cleanup
RESOURCE_FILE="/tmp/aws_rdma_resources.txt"

echo -e "${BLUE}=== AWS Soft-RoCE RDMA Deployment Script ===${NC}"
echo -e "${YELLOW}Instance Type: $INSTANCE_TYPE${NC}"
echo -e "${YELLOW}Region: $REGION${NC}"
echo

# Function to cleanup resources
cleanup_resources() {
    echo -e "${YELLOW}Cleaning up AWS resources...${NC}"
    if [ -f "$RESOURCE_FILE" ]; then
        source "$RESOURCE_FILE"
        
        # Terminate instance
        if [ ! -z "$INSTANCE_ID" ]; then
            aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$REGION" 2>/dev/null || true
            echo "Terminated instance: $INSTANCE_ID"
        fi
        
        # Delete security group (wait for instance termination)
        if [ ! -z "$SECURITY_GROUP_ID" ]; then
            sleep 30
            aws ec2 delete-security-group --group-id "$SECURITY_GROUP_ID" --region "$REGION" 2>/dev/null || true
            echo "Deleted security group: $SECURITY_GROUP_ID"
        fi
        
        # Delete key pair
        if [ ! -z "$KEY_NAME" ]; then
            aws ec2 delete-key-pair --key-name "$KEY_NAME" --region "$REGION" 2>/dev/null || true
            rm -f "${KEY_NAME}.pem"
            echo "Deleted key pair: $KEY_NAME"
        fi
        
        rm -f "$RESOURCE_FILE"
    fi
}

# Trap to cleanup on exit
trap cleanup_resources EXIT

# Check AWS CLI
if ! command -v aws &> /dev/null; then
    echo -e "${RED}AWS CLI not found. Please install it first.${NC}"
    echo "Install with: pip install awscli"
    exit 1
fi

# Check AWS credentials
if ! aws sts get-caller-identity &> /dev/null; then
    echo -e "${RED}AWS credentials not configured. Please run 'aws configure'${NC}"
    exit 1
fi

# Get latest Ubuntu 22.04 AMI
echo -e "${BLUE}Finding latest Ubuntu 22.04 AMI...${NC}"
AMI_ID=$(aws ec2 describe-images \
    --owners 099720109477 \
    --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
              "Name=state,Values=available" \
    --query 'Images[0].ImageId' \
    --output text \
    --region "$REGION")

if [ "$AMI_ID" == "None" ] || [ -z "$AMI_ID" ]; then
    echo -e "${RED}Failed to find Ubuntu 22.04 AMI${NC}"
    exit 1
fi

echo "Found AMI: $AMI_ID"

# Create key pair
echo -e "${BLUE}Creating SSH key pair...${NC}"
aws ec2 create-key-pair \
    --key-name "$KEY_NAME" \
    --query 'KeyMaterial' \
    --output text \
    --region "$REGION" > "${KEY_NAME}.pem"

chmod 600 "${KEY_NAME}.pem"
echo "Created key pair: $KEY_NAME"

# Create security group
echo -e "${BLUE}Creating security group...${NC}"
VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=is-default,Values=true" \
    --query 'Vpcs[0].VpcId' \
    --output text \
    --region "$REGION")

SECURITY_GROUP_ID=$(aws ec2 create-security-group \
    --group-name "$SECURITY_GROUP" \
    --description "Security group for RDMA testing" \
    --vpc-id "$VPC_ID" \
    --query 'GroupId' \
    --output text \
    --region "$REGION")

echo "Created security group: $SECURITY_GROUP_ID"

# Add security group rules
echo -e "${BLUE}Configuring security group rules...${NC}"
aws ec2 authorize-security-group-ingress \
    --group-id "$SECURITY_GROUP_ID" \
    --protocol tcp \
    --port 22 \
    --cidr 0.0.0.0/0 \
    --region "$REGION" > /dev/null

aws ec2 authorize-security-group-ingress \
    --group-id "$SECURITY_GROUP_ID" \
    --protocol tcp \
    --port 4433 \
    --cidr 0.0.0.0/0 \
    --region "$REGION" > /dev/null

aws ec2 authorize-security-group-ingress \
    --group-id "$SECURITY_GROUP_ID" \
    --protocol tcp \
    --port 4791 \
    --cidr 0.0.0.0/0 \
    --region "$REGION" > /dev/null

# Save resources for cleanup
echo "INSTANCE_ID=" > "$RESOURCE_FILE"
echo "SECURITY_GROUP_ID=$SECURITY_GROUP_ID" >> "$RESOURCE_FILE"
echo "KEY_NAME=$KEY_NAME" >> "$RESOURCE_FILE"
echo "REGION=$REGION" >> "$RESOURCE_FILE"

# Create user data script
cat > /tmp/user_data.sh << 'USERDATA'
#!/bin/bash
set -e

# Log output
exec > /var/log/rdma-setup.log 2>&1

echo "=== Starting RDMA Soft-RoCE Setup ==="
date

# Update system
apt-get update
apt-get upgrade -y

# Install development tools
apt-get install -y \
    build-essential \
    git \
    libssl-dev \
    cmake \
    pkg-config \
    python3-pip

# Install RDMA packages with Soft-RoCE support
apt-get install -y \
    libibverbs-dev \
    librdmacm-dev \
    ibverbs-utils \
    rdma-core \
    perftest \
    rdmacm-utils \
    infiniband-diags

# Load required kernel modules
modprobe ib_core
modprobe rdma_ucm
modprobe rdma_rxe

# Wait for network to be ready
sleep 5

# Configure Soft-RoCE on primary network interface
IFACE=$(ip route | grep default | awk '{print $5}' | head -1)
echo "Configuring Soft-RoCE on interface: $IFACE"

# Add RXE device
rdma link add rxe0 type rxe netdev $IFACE || true

# Verify RDMA setup
echo "=== RDMA Devices ==="
ibv_devices

echo "=== RDMA Device Info ==="
ibv_devinfo

# Create setup complete marker
touch /tmp/rdma-setup-complete

echo "=== RDMA Setup Complete ==="
date
USERDATA

# Launch instance
echo -e "${BLUE}Launching EC2 instance...${NC}"
INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SECURITY_GROUP_ID" \
    --user-data file:///tmp/user_data.sh \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME}]" \
    --query 'Instances[0].InstanceId' \
    --output text \
    --region "$REGION")

echo "Launched instance: $INSTANCE_ID"

# Update resource file with instance ID
sed -i.bak "s/INSTANCE_ID=/INSTANCE_ID=$INSTANCE_ID/" "$RESOURCE_FILE"

# Wait for instance to be running
echo -e "${BLUE}Waiting for instance to start...${NC}"
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"

# Get instance public IP
PUBLIC_IP=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text \
    --region "$REGION")

echo -e "${GREEN}Instance is running!${NC}"
echo "Public IP: $PUBLIC_IP"

# Wait for SSH to be ready
echo -e "${BLUE}Waiting for SSH to be ready...${NC}"
while ! ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "${KEY_NAME}.pem" ubuntu@"$PUBLIC_IP" "echo SSH ready" 2>/dev/null; do
    echo -n "."
    sleep 5
done
echo

# Wait for RDMA setup to complete
echo -e "${BLUE}Waiting for RDMA setup to complete...${NC}"
while ! ssh -o StrictHostKeyChecking=no -i "${KEY_NAME}.pem" ubuntu@"$PUBLIC_IP" "test -f /tmp/rdma-setup-complete" 2>/dev/null; do
    echo -n "."
    sleep 5
done
echo

# Create deployment script
cat > /tmp/deploy_project.sh << 'DEPLOY'
#!/bin/bash
set -e

echo "=== Deploying Secure RDMA Project ==="

# Clone or create project directory
if [ ! -d rdma-project ]; then
    mkdir -p rdma-project
fi

cd rdma-project

# Create project files
cat > Makefile << 'MAKEFILE'
CC = gcc
CFLAGS = -Wall -Wextra -O2 -g -D_GNU_SOURCE
LDFLAGS = -lrdmacm -libverbs -lpthread -lssl -lcrypto

TARGETS = secure_server secure_client

SRC_DIR = src
SECURE_SERVER_SRC = $(SRC_DIR)/secure_rdma_server.c $(SRC_DIR)/tls_utils.c
SECURE_CLIENT_SRC = $(SRC_DIR)/secure_rdma_client.c $(SRC_DIR)/tls_utils.c

INCLUDES = -I$(SRC_DIR)

all: $(TARGETS)

secure_server: $(SECURE_SERVER_SRC)
	$(CC) $(CFLAGS) $(INCLUDES) -o $@ $(SECURE_SERVER_SRC) $(LDFLAGS)

secure_client: $(SECURE_CLIENT_SRC)
	$(CC) $(CFLAGS) $(INCLUDES) -o $@ $(SECURE_CLIENT_SRC) $(LDFLAGS)

clean:
	rm -f $(TARGETS) *.o server.crt server.key

generate-cert:
	openssl req -x509 -newkey rsa:2048 -keyout server.key -out server.crt \
		-days 365 -nodes -subj '/CN=localhost'

.PHONY: all clean generate-cert
MAKEFILE

echo "Project directory created"
DEPLOY

# Copy project files to instance
echo -e "${BLUE}Copying project files to instance...${NC}"
scp -o StrictHostKeyChecking=no -i "${KEY_NAME}.pem" -r src ubuntu@"$PUBLIC_IP":~/rdma-project/ 2>/dev/null || true
scp -o StrictHostKeyChecking=no -i "${KEY_NAME}.pem" /tmp/deploy_project.sh ubuntu@"$PUBLIC_IP":~/ 2>/dev/null

# Run deployment
echo -e "${BLUE}Building project on instance...${NC}"
ssh -o StrictHostKeyChecking=no -i "${KEY_NAME}.pem" ubuntu@"$PUBLIC_IP" "bash deploy_project.sh && cd rdma-project && make clean && make all && make generate-cert"

# Create test script
cat > /tmp/run_rdma_test.sh << 'TEST'
#!/bin/bash
set -e

cd ~/rdma-project

echo "=== RDMA Environment Check ==="
ibv_devices
echo

echo "=== Starting Secure RDMA Server ==="
./secure_server > server.log 2>&1 &
SERVER_PID=$!
sleep 3

echo "=== Running Client Test ==="
echo -e "send Hello from AWS EC2 with Soft-RoCE\nquit" | ./secure_client 127.0.0.1 localhost

echo
echo "=== Server Log ==="
tail -20 server.log

# Cleanup
kill $SERVER_PID 2>/dev/null || true

echo
echo "=== Test Complete ==="
TEST

# Copy and run test
echo -e "${BLUE}Running RDMA test...${NC}"
scp -o StrictHostKeyChecking=no -i "${KEY_NAME}.pem" /tmp/run_rdma_test.sh ubuntu@"$PUBLIC_IP":~/rdma-project/ 2>/dev/null
ssh -o StrictHostKeyChecking=no -i "${KEY_NAME}.pem" ubuntu@"$PUBLIC_IP" "cd rdma-project && bash run_rdma_test.sh"

# Display connection info
echo
echo -e "${GREEN}=== Deployment Complete ===${NC}"
echo -e "${YELLOW}Instance Details:${NC}"
echo "  Instance ID: $INSTANCE_ID"
echo "  Public IP: $PUBLIC_IP"
echo "  SSH: ssh -i ${KEY_NAME}.pem ubuntu@$PUBLIC_IP"
echo
echo -e "${YELLOW}Test Commands:${NC}"
echo "  cd rdma-project"
echo "  ./secure_server"
echo "  ./secure_client 127.0.0.1 localhost"
echo
echo -e "${YELLOW}Monitoring:${NC}"
echo "  ibv_devices    # List RDMA devices"
echo "  ibv_devinfo    # Show device info"
echo "  rdma link show # Show RXE configuration"
echo
echo -e "${RED}To terminate and cleanup (when done):${NC}"
echo "  Press Ctrl+C or run: aws ec2 terminate-instances --instance-ids $INSTANCE_ID --region $REGION"
echo
echo "Cost: ~\$0.09/hour for t3.large"

# Keep script running to maintain resources
read -p "Press Enter to terminate instance and cleanup resources..."