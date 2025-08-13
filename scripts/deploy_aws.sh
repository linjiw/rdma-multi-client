#!/bin/bash

# AWS EC2 deployment script for RDMA testing with EFA
# Requires AWS CLI configured with appropriate credentials

set -e

# Configuration
INSTANCE_TYPE="c5n.large"  # EFA-enabled instance
AMI_ID="ami-0c55b159cbfafe1f0"  # Ubuntu 22.04 (update for your region)
KEY_NAME="rdma-test-key"
SECURITY_GROUP="rdma-test-sg"
INSTANCE_NAME="rdma-test-instance"

echo "=== Deploying RDMA Test Environment to AWS ==="

# Create key pair if it doesn't exist
if ! aws ec2 describe-key-pairs --key-names $KEY_NAME &>/dev/null; then
    echo "Creating key pair..."
    aws ec2 create-key-pair --key-name $KEY_NAME --query 'KeyMaterial' --output text > ~/.ssh/$KEY_NAME.pem
    chmod 400 ~/.ssh/$KEY_NAME.pem
fi

# Create security group if it doesn't exist
if ! aws ec2 describe-security-groups --group-names $SECURITY_GROUP &>/dev/null; then
    echo "Creating security group..."
    VPC_ID=$(aws ec2 describe-vpcs --query 'Vpcs[0].VpcId' --output text)
    SG_ID=$(aws ec2 create-security-group \
        --group-name $SECURITY_GROUP \
        --description "Security group for RDMA testing" \
        --vpc-id $VPC_ID \
        --output text)
    
    # Allow SSH
    aws ec2 authorize-security-group-ingress \
        --group-id $SG_ID \
        --protocol tcp \
        --port 22 \
        --cidr 0.0.0.0/0
    
    # Allow TLS port
    aws ec2 authorize-security-group-ingress \
        --group-id $SG_ID \
        --protocol tcp \
        --port 4433 \
        --cidr 0.0.0.0/0
    
    # Allow RDMA port
    aws ec2 authorize-security-group-ingress \
        --group-id $SG_ID \
        --protocol tcp \
        --port 4791 \
        --cidr 0.0.0.0/0
else
    SG_ID=$(aws ec2 describe-security-groups --group-names $SECURITY_GROUP --query 'SecurityGroups[0].GroupId' --output text)
fi

# Launch instance with EFA
echo "Launching EC2 instance with EFA..."
INSTANCE_ID=$(aws ec2 run-instances \
    --image-id $AMI_ID \
    --instance-type $INSTANCE_TYPE \
    --key-name $KEY_NAME \
    --security-group-ids $SG_ID \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$INSTANCE_NAME}]" \
    --efa-support \
    --query 'Instances[0].InstanceId' \
    --output text)

echo "Instance ID: $INSTANCE_ID"

# Wait for instance to be running
echo "Waiting for instance to start..."
aws ec2 wait instance-running --instance-ids $INSTANCE_ID

# Get public IP
PUBLIC_IP=$(aws ec2 describe-instances \
    --instance-ids $INSTANCE_ID \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)

echo "Instance public IP: $PUBLIC_IP"

# Wait for SSH to be available
echo "Waiting for SSH to be available..."
while ! ssh -o StrictHostKeyChecking=no -i ~/.ssh/$KEY_NAME.pem ubuntu@$PUBLIC_IP "echo SSH ready" &>/dev/null; do
    sleep 5
done

# Create setup script
cat > /tmp/setup_rdma.sh << 'SETUP_SCRIPT'
#!/bin/bash
set -e

# Update system
sudo apt-get update
sudo apt-get install -y build-essential git libssl-dev

# Install EFA driver
curl -O https://efa-installer.amazonaws.com/aws-efa-installer-latest.tar.gz
tar -xf aws-efa-installer-latest.tar.gz
cd aws-efa-installer
sudo ./efa_installer.sh -y
cd ..

# Install RDMA packages
sudo apt-get install -y \
    libibverbs-dev \
    librdmacm-dev \
    ibverbs-utils \
    rdma-core \
    perftest

# Clone and build project
git clone https://github.com/yourusername/rdma-project.git || {
    # If no GitHub repo, we'll copy files later
    mkdir rdma-project
}

cd rdma-project

# Verify EFA device
fi_info -p efa

# Show RDMA devices
ibv_devices
SETUP_SCRIPT

# Copy setup script and run
echo "Setting up RDMA environment on instance..."
scp -i ~/.ssh/$KEY_NAME.pem /tmp/setup_rdma.sh ubuntu@$PUBLIC_IP:~/
ssh -i ~/.ssh/$KEY_NAME.pem ubuntu@$PUBLIC_IP "chmod +x setup_rdma.sh && ./setup_rdma.sh"

# Copy project files
echo "Copying project files..."
rsync -avz -e "ssh -i ~/.ssh/$KEY_NAME.pem" \
    --exclude='.git' \
    --exclude='*.o' \
    --exclude='rdma-core' \
    --exclude='libibverbs' \
    ./ ubuntu@$PUBLIC_IP:~/rdma-project/

# Build and test on remote
echo "Building and testing on remote instance..."
ssh -i ~/.ssh/$KEY_NAME.pem ubuntu@$PUBLIC_IP << 'REMOTE_TEST'
cd rdma-project
make clean
make all
make generate-cert

# Run tests
echo "=== Running RDMA tests with EFA ==="
./tests/test_secure_rdma.sh

# Run performance benchmark
echo "=== Performance Benchmark ==="
./secure_server &
SERVER_PID=$!
sleep 2

# Benchmark with single client
time (for i in {1..100}; do echo -e "send Message $i\nquit"; done | ./secure_client 127.0.0.1 localhost)

kill $SERVER_PID

echo "=== Tests completed ==="
REMOTE_TEST

echo ""
echo "=== Deployment Complete ==="
echo "Instance ID: $INSTANCE_ID"
echo "Public IP: $PUBLIC_IP"
echo ""
echo "To connect:"
echo "  ssh -i ~/.ssh/$KEY_NAME.pem ubuntu@$PUBLIC_IP"
echo ""
echo "To terminate instance:"
echo "  aws ec2 terminate-instances --instance-ids $INSTANCE_ID"
echo ""
echo "To run demo:"
echo "  ssh -i ~/.ssh/$KEY_NAME.pem ubuntu@$PUBLIC_IP 'cd rdma-project && ./run_demo.sh'"