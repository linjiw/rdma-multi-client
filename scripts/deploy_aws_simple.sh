#!/bin/bash

# Simplified AWS Deployment for Secure RDMA Testing
set -e

# Configuration
REGION="us-east-1"
INSTANCE_TYPE="t3.large"
KEY_NAME="rdma-test-$(date +%s)"
SG_NAME="rdma-sg-$(date +%s)"

echo "=== AWS Secure RDMA Deployment ==="
echo "Region: $REGION"
echo "Instance: $INSTANCE_TYPE"
echo

# Get Ubuntu 22.04 AMI
echo "Finding Ubuntu 22.04 AMI..."
AMI_ID=$(aws ec2 describe-images \
    --owners 099720109477 \
    --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
    --query 'Images[0].ImageId' \
    --output text \
    --region $REGION)

echo "AMI ID: $AMI_ID"

# Create key pair
echo "Creating key pair..."
aws ec2 create-key-pair \
    --key-name $KEY_NAME \
    --query 'KeyMaterial' \
    --output text \
    --region $REGION > ${KEY_NAME}.pem

chmod 600 ${KEY_NAME}.pem
echo "Key saved: ${KEY_NAME}.pem"

# Get default VPC
VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=is-default,Values=true" \
    --query 'Vpcs[0].VpcId' \
    --output text \
    --region $REGION)

# Create security group
echo "Creating security group..."
SG_ID=$(aws ec2 create-security-group \
    --group-name $SG_NAME \
    --description "RDMA test SG" \
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

echo "Security group: $SG_ID"

# Create user data script
cat > /tmp/userdata.sh << 'EOF'
#!/bin/bash
apt-get update
apt-get install -y build-essential git libssl-dev libibverbs-dev librdmacm-dev rdma-core perftest
modprobe rdma_rxe
IFACE=$(ip route | grep default | awk '{print $5}')
rdma link add rxe0 type rxe netdev $IFACE || true
touch /tmp/setup-done
EOF

# Launch instance
echo "Launching instance..."
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
echo "Waiting for instance to start..."
aws ec2 wait instance-running --instance-ids $INSTANCE_ID --region $REGION

# Get IP
PUBLIC_IP=$(aws ec2 describe-instances \
    --instance-ids $INSTANCE_ID \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text \
    --region $REGION)

echo
echo "=== Instance Ready ==="
echo "IP: $PUBLIC_IP"
echo "SSH: ssh -i ${KEY_NAME}.pem ubuntu@$PUBLIC_IP"
echo "State saved to: aws_state.txt"