#!/bin/bash

# Deploy Ubuntu 20.04 with working Soft-RoCE
set -e

REGION="us-east-1"
INSTANCE_TYPE="t3.large"
KEY_NAME="rdma-ubuntu20-$(date +%s)"
SG_NAME="rdma-sg-$(date +%s)"

echo "=== Deploying Ubuntu 20.04 with Soft-RoCE ==="

# Ubuntu 20.04 AMI (has working rdma_rxe)
AMI_ID="ami-0c4f7023847b90238"  # Ubuntu 20.04 LTS in us-east-1

# Create key pair
aws ec2 create-key-pair \
    --key-name $KEY_NAME \
    --query 'KeyMaterial' \
    --output text \
    --region $REGION > ${KEY_NAME}.pem
chmod 600 ${KEY_NAME}.pem

# Get VPC
VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=is-default,Values=true" \
    --query 'Vpcs[0].VpcId' \
    --output text \
    --region $REGION)

# Create security group
SG_ID=$(aws ec2 create-security-group \
    --group-name $SG_NAME \
    --description "RDMA test" \
    --vpc-id $VPC_ID \
    --query 'GroupId' \
    --output text \
    --region $REGION)

# Add rules
aws ec2 authorize-security-group-ingress \
    --group-id $SG_ID \
    --protocol tcp --port 22 --cidr 0.0.0.0/0 \
    --region $REGION > /dev/null

aws ec2 authorize-security-group-ingress \
    --group-id $SG_ID \
    --protocol tcp --port 4433 --cidr 0.0.0.0/0 \
    --region $REGION > /dev/null

aws ec2 authorize-security-group-ingress \
    --group-id $SG_ID \
    --protocol tcp --port 4791 --cidr 0.0.0.0/0 \
    --region $REGION > /dev/null

# User data to setup RDMA
cat > /tmp/userdata.sh << 'EOF'
#!/bin/bash
apt-get update
apt-get install -y build-essential libssl-dev libibverbs-dev librdmacm-dev rdma-core ibverbs-utils perftest

# Load RDMA modules
modprobe ib_core
modprobe rdma_ucm
modprobe rdma_rxe

# Setup Soft-RoCE
IFACE=$(ip route | grep default | awk '{print $5}')
rdma link add rxe0 type rxe netdev $IFACE

# Verify
ibv_devices > /tmp/rdma_devices.txt
touch /tmp/rdma-ready
EOF

# Launch instance
INSTANCE_ID=$(aws ec2 run-instances \
    --image-id $AMI_ID \
    --instance-type $INSTANCE_TYPE \
    --key-name $KEY_NAME \
    --security-group-ids $SG_ID \
    --user-data file:///tmp/userdata.sh \
    --query 'Instances[0].InstanceId' \
    --output text \
    --region $REGION)

echo "Instance ID: $INSTANCE_ID"

# Save state
cat > aws_state.txt << EOF
INSTANCE_ID=$INSTANCE_ID
KEY_NAME=$KEY_NAME
SG_ID=$SG_ID
REGION=$REGION
EOF

# Wait for instance
aws ec2 wait instance-running --instance-ids $INSTANCE_ID --region $REGION

# Get IP
PUBLIC_IP=$(aws ec2 describe-instances \
    --instance-ids $INSTANCE_ID \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text \
    --region $REGION)

echo
echo "=== Ubuntu 20.04 Instance Ready ==="
echo "IP: $PUBLIC_IP"
echo "Key: ${KEY_NAME}.pem"
echo "SSH: ssh -i ${KEY_NAME}.pem ubuntu@$PUBLIC_IP"