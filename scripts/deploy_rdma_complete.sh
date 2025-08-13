#!/bin/bash

# Complete RDMA Deployment Script for AWS
# This script automates the entire deployment process for the secure RDMA project
# Version: 1.0
# Date: August 2025

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
PROJECT_NAME="rdma-project"
KEY_PREFIX="rdma-key"
INSTANCE_TYPE="t3.large"
DEFAULT_REGION="us-west-2"
UBUNTU_20_04_AMI="ami-036d46416a34a611c"  # Ubuntu 20.04 in us-west-2
SECURITY_GROUP_NAME="rdma-security-group"

# Function to print colored messages
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Function to check prerequisites
check_prerequisites() {
    print_info "Checking prerequisites..."
    
    # Check AWS CLI
    if ! command -v aws &> /dev/null; then
        print_error "AWS CLI not found. Please install it first."
        echo "Visit: https://aws.amazon.com/cli/"
        exit 1
    fi
    
    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        print_error "AWS credentials not configured. Run: aws configure"
        exit 1
    fi
    
    # Check git
    if ! command -v git &> /dev/null; then
        print_error "Git not found. Please install git."
        exit 1
    fi
    
    # Check SSH
    if ! command -v ssh &> /dev/null; then
        print_error "SSH client not found."
        exit 1
    fi
    
    print_success "All prerequisites met"
}

# Function to get or create VPC
get_vpc_id() {
    print_info "Getting VPC ID..."
    VPC_ID=$(aws ec2 describe-vpcs \
        --filters "Name=is-default,Values=true" \
        --query 'Vpcs[0].VpcId' \
        --output text 2>/dev/null || echo "")
    
    if [ -z "$VPC_ID" ] || [ "$VPC_ID" == "None" ]; then
        print_error "No default VPC found. Creating one is beyond this script's scope."
        exit 1
    fi
    
    print_success "VPC ID: $VPC_ID"
    echo "$VPC_ID"
}

# Function to create security group
create_security_group() {
    local vpc_id=$1
    print_info "Creating security group..."
    
    # Check if security group exists
    SG_ID=$(aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=$SECURITY_GROUP_NAME" \
        --query 'SecurityGroups[0].GroupId' \
        --output text 2>/dev/null || echo "")
    
    if [ -n "$SG_ID" ] && [ "$SG_ID" != "None" ]; then
        print_warning "Security group already exists: $SG_ID"
    else
        # Create security group
        SG_ID=$(aws ec2 create-security-group \
            --group-name "$SECURITY_GROUP_NAME" \
            --description "Security group for RDMA testing" \
            --vpc-id "$vpc_id" \
            --output text)
        
        print_success "Created security group: $SG_ID"
        
        # Add rules
        print_info "Adding security group rules..."
        
        # SSH
        aws ec2 authorize-security-group-ingress \
            --group-id "$SG_ID" \
            --protocol tcp \
            --port 22 \
            --cidr 0.0.0.0/0 &>/dev/null || true
        
        # TLS server
        aws ec2 authorize-security-group-ingress \
            --group-id "$SG_ID" \
            --protocol tcp \
            --port 4433 \
            --cidr 0.0.0.0/0 &>/dev/null || true
        
        # RDMA server
        aws ec2 authorize-security-group-ingress \
            --group-id "$SG_ID" \
            --protocol tcp \
            --port 4791 \
            --cidr 0.0.0.0/0 &>/dev/null || true
        
        # VS Code Server (optional)
        aws ec2 authorize-security-group-ingress \
            --group-id "$SG_ID" \
            --protocol tcp \
            --port 8080 \
            --cidr 0.0.0.0/0 &>/dev/null || true
        
        print_success "Security group rules added"
    fi
    
    echo "$SG_ID"
}

# Function to create key pair
create_key_pair() {
    local key_name="${KEY_PREFIX}-$(date +%s)"
    print_info "Creating key pair: $key_name"
    
    # Create key pair and save to file
    aws ec2 create-key-pair \
        --key-name "$key_name" \
        --query 'KeyMaterial' \
        --output text > "${key_name}.pem"
    
    chmod 600 "${key_name}.pem"
    print_success "Key pair created: ${key_name}.pem"
    echo "$key_name"
}

# Function to launch instance
launch_instance() {
    local sg_id=$1
    local key_name=$2
    
    print_info "Launching EC2 instance..."
    
    # Create user data script
    cat > /tmp/user_data.sh << 'EOF'
#!/bin/bash
apt-get update
apt-get upgrade -y

# Install basic tools
apt-get install -y build-essential git vim htop net-tools

# Install RDMA packages
apt-get install -y rdma-core libibverbs-dev librdmacm-dev ibverbs-utils rdmacm-utils perftest infiniband-diags

# Install SSL libraries
apt-get install -y libssl-dev openssl

# Install HWE kernel for RDMA support
apt-get install -y linux-generic-hwe-20.04

# Load RDMA modules
modprobe ib_core
modprobe rdma_ucm
modprobe rdma_rxe

# Setup will continue after reboot
EOF
    
    # Launch instance
    INSTANCE_ID=$(aws ec2 run-instances \
        --image-id "$UBUNTU_20_04_AMI" \
        --instance-type "$INSTANCE_TYPE" \
        --key-name "$key_name" \
        --security-group-ids "$sg_id" \
        --user-data file:///tmp/user_data.sh \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$PROJECT_NAME},{Key=Purpose,Value=RDMA-Testing}]" \
        --query 'Instances[0].InstanceId' \
        --output text)
    
    print_success "Instance launched: $INSTANCE_ID"
    
    # Wait for instance to be running
    print_info "Waiting for instance to be running..."
    aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
    
    # Get public IP
    PUBLIC_IP=$(aws ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text)
    
    print_success "Instance is running at: $PUBLIC_IP"
    
    echo "$INSTANCE_ID|$PUBLIC_IP"
}

# Function to wait for SSH
wait_for_ssh() {
    local ip=$1
    local key_file=$2
    
    print_info "Waiting for SSH to be available..."
    
    for i in {1..60}; do
        if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "$key_file" ubuntu@"$ip" "echo connected" &>/dev/null; then
            print_success "SSH is ready"
            return 0
        fi
        echo -n "."
        sleep 5
    done
    
    print_error "SSH connection timeout"
    return 1
}

# Function to setup RDMA on instance
setup_rdma_on_instance() {
    local ip=$1
    local key_file=$2
    
    print_info "Setting up RDMA on instance..."
    
    # Create setup script
    cat > /tmp/setup_rdma.sh << 'EOF'
#!/bin/bash
set -e

echo "=== Setting up RDMA Environment ==="

# Wait for any apt locks to be released
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
    echo "Waiting for apt lock..."
    sleep 2
done

# Update and install packages if needed
sudo apt-get update
sudo apt-get install -y linux-modules-extra-$(uname -r) 2>/dev/null || true

# Load RDMA modules
sudo modprobe ib_core
sudo modprobe rdma_ucm
sudo modprobe rdma_rxe

# Setup Soft-RoCE
IFACE=$(ip route | grep default | awk '{print $5}')
sudo rdma link add rxe0 type rxe netdev $IFACE 2>/dev/null || echo "rxe0 already exists"

# Verify RDMA setup
echo "Verifying RDMA setup..."
ibv_devices
ibv_devinfo -d rxe0 | head -20

# Make modules persistent
echo "ib_core" | sudo tee -a /etc/modules
echo "rdma_ucm" | sudo tee -a /etc/modules
echo "rdma_rxe" | sudo tee -a /etc/modules

# Create systemd service for Soft-RoCE
sudo tee /etc/systemd/system/rdma-setup.service << 'SERVICE'
[Unit]
Description=Setup RDMA Soft-RoCE
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'rdma link add rxe0 type rxe netdev $(ip route | grep default | awk "{print \$5}") 2>/dev/null || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SERVICE

sudo systemctl enable rdma-setup.service

echo "=== RDMA Setup Complete ==="
EOF
    
    # Copy and run setup script
    scp -o StrictHostKeyChecking=no -i "$key_file" /tmp/setup_rdma.sh ubuntu@"$ip":/tmp/
    ssh -o StrictHostKeyChecking=no -i "$key_file" ubuntu@"$ip" "chmod +x /tmp/setup_rdma.sh && /tmp/setup_rdma.sh"
    
    print_success "RDMA setup completed"
}

# Function to deploy project
deploy_project() {
    local ip=$1
    local key_file=$2
    
    print_info "Deploying project to instance..."
    
    # Create deployment package
    print_info "Creating deployment package..."
    TEMP_DIR=$(mktemp -d)
    
    # Copy project files
    cp -r src "$TEMP_DIR/" 2>/dev/null || true
    cp -r docs "$TEMP_DIR/" 2>/dev/null || true
    cp -r scripts "$TEMP_DIR/" 2>/dev/null || true
    cp Makefile "$TEMP_DIR/" 2>/dev/null || true
    cp *.md "$TEMP_DIR/" 2>/dev/null || true
    
    # Create Makefile if it doesn't exist
    if [ ! -f "$TEMP_DIR/Makefile" ]; then
        cat > "$TEMP_DIR/Makefile" << 'EOF'
CC = gcc
CFLAGS = -Wall -Wextra -O2 -g -D_GNU_SOURCE
LDFLAGS = -lrdmacm -libverbs -lpthread -lssl -lcrypto

all: secure_server secure_client

secure_server: src/secure_rdma_server.c src/tls_utils.c
	$(CC) $(CFLAGS) -I./src -o $@ $^ $(LDFLAGS)

secure_client: src/secure_rdma_client.c src/tls_utils.c
	$(CC) $(CFLAGS) -I./src -o $@ $^ $(LDFLAGS)

generate-cert:
	openssl req -x509 -newkey rsa:4096 -keyout server.key -out server.crt -days 365 -nodes \
		-subj "/C=US/ST=State/L=City/O=Organization/CN=localhost"

clean:
	rm -f secure_server secure_client server.crt server.key *.o

test: all generate-cert
	@echo "Running basic test..."
	./secure_server &
	sleep 2
	echo "quit" | ./secure_client 127.0.0.1 localhost
	killall secure_server 2>/dev/null || true

.PHONY: all clean generate-cert test
EOF
    fi
    
    # Create tarball
    cd "$TEMP_DIR"
    tar -czf rdma-project.tar.gz *
    
    # Copy to instance
    scp -o StrictHostKeyChecking=no -i "$key_file" rdma-project.tar.gz ubuntu@"$ip":/home/ubuntu/
    
    # Extract and build on instance
    ssh -o StrictHostKeyChecking=no -i "$key_file" ubuntu@"$ip" << 'EOF'
mkdir -p ~/rdma-project
cd ~/rdma-project
tar -xzf ~/rdma-project.tar.gz
rm ~/rdma-project.tar.gz

# Build the project
echo "Building project..."
make clean
make all
make generate-cert

# Create test script
cat > test_deployment.sh << 'SCRIPT'
#!/bin/bash
echo "=== Testing RDMA Deployment ==="

# Check RDMA device
echo "1. RDMA Device:"
ibv_devices

# Test server
echo "2. Starting server..."
./secure_server > server.log 2>&1 &
SERVER_PID=$!
sleep 3

# Test client
echo "3. Testing client connection..."
echo "quit" | timeout 10 ./secure_client 127.0.0.1 localhost

# Cleanup
kill $SERVER_PID 2>/dev/null

echo "=== Test Complete ==="
SCRIPT

chmod +x test_deployment.sh

# Run test
./test_deployment.sh

echo "Project deployed successfully!"
EOF
    
    # Cleanup
    rm -rf "$TEMP_DIR"
    
    print_success "Project deployed and tested"
}

# Function to create SSH config
create_ssh_config() {
    local ip=$1
    local key_file=$2
    local instance_id=$3
    
    print_info "Creating SSH configuration..."
    
    # Create SSH config entry
    cat >> ~/.ssh/config << EOF

# RDMA AWS Instance (Auto-generated)
Host rdma-aws
    HostName $ip
    User ubuntu
    Port 22
    IdentityFile $(pwd)/$key_file
    ServerAliveInterval 60
    ServerAliveCountMax 3
    TCPKeepAlive yes
    ForwardAgent yes
    # Optional port forwards
    LocalForward 8080 localhost:8080  # VS Code Server
    LocalForward 4433 localhost:4433  # TLS Server
    LocalForward 4791 localhost:4791  # RDMA Server
    # Instance ID: $instance_id
EOF
    
    print_success "SSH config added. You can now connect with: ssh rdma-aws"
}

# Function to create management script
create_management_script() {
    local instance_id=$1
    local key_file=$2
    local ip=$3
    
    print_info "Creating management script..."
    
    cat > manage_rdma_instance.sh << EOF
#!/bin/bash
# RDMA Instance Management Script
# Instance ID: $instance_id
# IP: $ip
# Key: $key_file

case "\$1" in
    start)
        echo "Starting instance..."
        aws ec2 start-instances --instance-ids $instance_id
        aws ec2 wait instance-running --instance-ids $instance_id
        NEW_IP=\$(aws ec2 describe-instances --instance-ids $instance_id --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
        echo "Instance started at: \$NEW_IP"
        ;;
    stop)
        echo "Stopping instance..."
        aws ec2 stop-instances --instance-ids $instance_id
        aws ec2 wait instance-stopped --instance-ids $instance_id
        echo "Instance stopped"
        ;;
    status)
        aws ec2 describe-instances --instance-ids $instance_id --query 'Reservations[0].Instances[0].State.Name' --output text
        ;;
    connect)
        ssh -i $key_file ubuntu@$ip
        ;;
    terminate)
        read -p "Are you sure you want to terminate the instance? (yes/no): " confirm
        if [ "\$confirm" == "yes" ]; then
            aws ec2 terminate-instances --instance-ids $instance_id
            echo "Instance terminated"
        fi
        ;;
    *)
        echo "Usage: \$0 {start|stop|status|connect|terminate}"
        exit 1
        ;;
esac
EOF
    
    chmod +x manage_rdma_instance.sh
    print_success "Management script created: manage_rdma_instance.sh"
}

# Function to display summary
display_summary() {
    local instance_id=$1
    local ip=$2
    local key_file=$3
    local sg_id=$4
    
    echo ""
    echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}           RDMA AWS DEPLOYMENT COMPLETE${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${GREEN}Instance Details:${NC}"
    echo "  Instance ID:     $instance_id"
    echo "  Public IP:       $ip"
    echo "  Instance Type:   $INSTANCE_TYPE"
    echo "  Region:          $DEFAULT_REGION"
    echo "  Security Group:  $sg_id"
    echo ""
    echo -e "${GREEN}Access Information:${NC}"
    echo "  SSH Key:         $key_file"
    echo "  SSH Command:     ssh -i $key_file ubuntu@$ip"
    echo "  Quick Connect:   ssh rdma-aws"
    echo ""
    echo -e "${GREEN}Project Location:${NC}"
    echo "  Remote Path:     /home/ubuntu/rdma-project"
    echo "  Server Binary:   /home/ubuntu/rdma-project/secure_server"
    echo "  Client Binary:   /home/ubuntu/rdma-project/secure_client"
    echo ""
    echo -e "${GREEN}Management:${NC}"
    echo "  Start Instance:  ./manage_rdma_instance.sh start"
    echo "  Stop Instance:   ./manage_rdma_instance.sh stop"
    echo "  Connect:         ./manage_rdma_instance.sh connect"
    echo "  Status:          ./manage_rdma_instance.sh status"
    echo ""
    echo -e "${GREEN}Testing:${NC}"
    echo "  ssh rdma-aws"
    echo "  cd rdma-project"
    echo "  ./test_deployment.sh"
    echo ""
    echo -e "${YELLOW}Cost Information:${NC}"
    echo "  Hourly Cost:     \$0.0882 (t3.large)"
    echo "  Daily Cost:      \$2.12"
    echo "  Monthly Cost:    ~\$63.50"
    echo ""
    echo -e "${YELLOW}Important:${NC}"
    echo "  Remember to stop the instance when not in use!"
    echo "  Use: ./manage_rdma_instance.sh stop"
    echo ""
    echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
}

# Main deployment function
main() {
    echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}           RDMA AWS DEPLOYMENT SCRIPT${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Check prerequisites
    check_prerequisites
    
    # Get VPC
    VPC_ID=$(get_vpc_id)
    
    # Create security group
    SG_ID=$(create_security_group "$VPC_ID")
    
    # Create key pair
    KEY_NAME=$(create_key_pair)
    KEY_FILE="${KEY_NAME}.pem"
    
    # Launch instance
    INSTANCE_INFO=$(launch_instance "$SG_ID" "$KEY_NAME")
    INSTANCE_ID=$(echo "$INSTANCE_INFO" | cut -d'|' -f1)
    PUBLIC_IP=$(echo "$INSTANCE_INFO" | cut -d'|' -f2)
    
    # Wait for SSH
    wait_for_ssh "$PUBLIC_IP" "$KEY_FILE"
    
    # Setup RDMA
    setup_rdma_on_instance "$PUBLIC_IP" "$KEY_FILE"
    
    # Deploy project
    deploy_project "$PUBLIC_IP" "$KEY_FILE"
    
    # Create SSH config
    create_ssh_config "$PUBLIC_IP" "$KEY_FILE" "$INSTANCE_ID"
    
    # Create management script
    create_management_script "$INSTANCE_ID" "$KEY_FILE" "$PUBLIC_IP"
    
    # Display summary
    display_summary "$INSTANCE_ID" "$PUBLIC_IP" "$KEY_FILE" "$SG_ID"
    
    # Save deployment info
    cat > deployment_info.json << EOF
{
    "instance_id": "$INSTANCE_ID",
    "public_ip": "$PUBLIC_IP",
    "key_file": "$KEY_FILE",
    "security_group": "$SG_ID",
    "region": "$DEFAULT_REGION",
    "deployment_date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
    
    print_success "Deployment completed successfully!"
    print_info "Deployment info saved to: deployment_info.json"
}

# Handle arguments
case "${1:-}" in
    --help|-h)
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  --region REGION    Specify AWS region (default: us-west-2)"
        echo "  --type TYPE        Specify instance type (default: t3.large)"
        echo "  --help             Show this help message"
        echo ""
        echo "This script will:"
        echo "  1. Launch an AWS EC2 instance with Ubuntu 20.04"
        echo "  2. Install and configure RDMA (Soft-RoCE)"
        echo "  3. Deploy the secure RDMA project"
        echo "  4. Setup SSH configuration for easy access"
        echo "  5. Create management scripts"
        exit 0
        ;;
    --region)
        DEFAULT_REGION="$2"
        shift 2
        ;;
    --type)
        INSTANCE_TYPE="$2"
        shift 2
        ;;
esac

# Run main deployment
main