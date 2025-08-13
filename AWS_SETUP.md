# AWS Setup Guide for RDMA with Soft-RoCE

## AWS Instance Requirements

### ⚠️ IMPORTANT: Instance Selection
**Not all AWS instances support Soft-RoCE properly!**

### Verified Working Configuration
- **Tested and Confirmed**: `t3.large` with specific setup
  - **OS**: Ubuntu 20.04 LTS (NOT 22.04 - kernel module issues!)
  - **Kernel**: 5.15.0-139-generic (HWE kernel required)
  - **Instance**: Current testing on ip-172-31-34-15 (us-east-1)
  - **Critical**: Must install linux-generic-hwe-20.04 for rdma_rxe module
  - **Network**: Standard AWS VPC with eth0/ens5 interface

### Instance Requirements
1. **Kernel Module Support**: Instance must support loading `rdma_rxe` module
2. **Network Interface**: Must have standard ethernet interface (eth0/ens5)
3. **Memory**: Minimum 4GB RAM (8GB recommended)
4. **vCPUs**: Minimum 2 vCPUs for multi-client testing

### Known Issues with Other Instances
- **t2 instances**: May have issues with kernel modules
- **ARM-based instances**: Not tested, may have compatibility issues
- **Micro/Nano instances**: Insufficient resources for 10 clients
- **Container-optimized AMIs**: Missing required kernel modules

### Region
Any region works, but ensure low latency if testing between instances.

## Step-by-Step AWS Setup

### 1. Launch EC2 Instance

```bash
# Using AWS CLI
aws ec2 run-instances \
  --image-id ami-0c94855ba95c574c8 \
  --instance-type t3.large \
  --key-name your-key-pair \
  --security-group-ids sg-xxxxxxxx \
  --subnet-id subnet-xxxxxxxx \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=rdma-test}]'
```

Or use AWS Console:
1. Go to EC2 Dashboard → Launch Instance
2. **CRITICAL**: Choose **Ubuntu Server 20.04 LTS** (NOT 22.04!)
   - Search for "ubuntu 20.04" in AMI search
   - Select "Ubuntu Server 20.04 LTS (HVM), SSD Volume Type"
3. Select **t3.large** instance type (verified working)
4. Configure Security Group (see below)
5. Add 20-30 GB storage
6. Launch

### 2. Security Group Configuration

Create or modify security group with these rules:

| Type | Protocol | Port Range | Source | Description |
|------|----------|------------|--------|-------------|
| SSH | TCP | 22 | Your IP | SSH access |
| Custom TCP | TCP | 4433 | 0.0.0.0/0 | TLS server |
| Custom TCP | TCP | 4791 | 0.0.0.0/0 | RDMA port |
| All ICMP | ICMP | All | 0.0.0.0/0 | Ping |

```bash
# Create security group
aws ec2 create-security-group \
  --group-name rdma-sg \
  --description "Security group for RDMA testing"

# Add rules
aws ec2 authorize-security-group-ingress \
  --group-name rdma-sg \
  --protocol tcp \
  --port 22 \
  --cidr your-ip/32

aws ec2 authorize-security-group-ingress \
  --group-name rdma-sg \
  --protocol tcp \
  --port 4433 \
  --cidr 0.0.0.0/0

aws ec2 authorize-security-group-ingress \
  --group-name rdma-sg \
  --protocol tcp \
  --port 4791 \
  --cidr 0.0.0.0/0
```

### 3. Connect to Instance

```bash
# SSH into your instance
ssh -i your-key.pem ubuntu@<instance-public-ip>

# Or if using Ubuntu 22.04
ssh -i your-key.pem ubuntu@<instance-public-ip>
```

## Software Installation

### 1. Update System

```bash
# Update package list
sudo apt-get update
sudo apt-get upgrade -y

# Install essential tools
sudo apt-get install -y \
  build-essential \
  git \
  vim \
  htop \
  net-tools \
  iproute2
```

### 2. Install RDMA Dependencies

```bash
# Install RDMA libraries and tools
sudo apt-get install -y \
  libibverbs-dev \
  librdmacm-dev \
  rdma-core \
  ibverbs-utils \
  rdmacm-utils \
  perftest \
  infiniband-diags

# Install SSL/TLS libraries
sudo apt-get install -y \
  libssl-dev \
  openssl
```

### 3. Configure Soft-RoCE

```bash
# Load necessary kernel modules
sudo modprobe rdma_rxe
sudo modprobe ib_core
sudo modprobe rdma_ucm

# Verify modules loaded
lsmod | grep rdma

# Add Soft-RoCE device (rxe0) on main network interface
# First, find your network interface (usually eth0 or ens5 on AWS)
ip link show

# Add rxe device (replace eth0 with your interface)
sudo rdma link add rxe0 type rxe netdev eth0

# Verify RDMA device created
ibv_devices

# Should show:
#     device                 node GUID
#     ------              ----------------
#     rxe0                xxxxxxxxxxxxxxxxxxxx
```

### 4. Make Soft-RoCE Persistent (Optional)

```bash
# Add to /etc/modules
echo "rdma_rxe" | sudo tee -antml:parameter /etc/modules

# Create systemd service for rxe device
sudo cat > /etc/systemd/system/soft-roce.service << EOF
[Unit]
Description=Configure Soft-RoCE
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/bin/rdma link add rxe0 type rxe netdev eth0
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Enable service
sudo systemctl enable soft-roce.service
```

## Clone and Build Project

```bash
# Clone the repository
git clone https://github.com/linjiw/rmda-multi-client.git
cd rmda-multi-client

# Build the project
make clean && make all

# Generate certificates
make generate-cert

# Verify build
ls -la build/
```

## Running the Demo

### Quick Test
```bash
# Run automated demo
./run_demo_auto.sh
```

### Manual Test
Terminal 1:
```bash
./build/secure_server
```

Terminal 2:
```bash
./build/secure_client 127.0.0.1 localhost
```

## Testing Between Two AWS Instances

### Setup Two Instances
1. Launch two EC2 instances with same configuration
2. Note both private IPs
3. Ensure they're in same VPC/subnet
4. Security group allows communication between them

### On Server Instance
```bash
# Start server
./build/secure_server
```

### On Client Instance
```bash
# Connect using private IP
./build/secure_client <server-private-ip> <server-private-ip>
```

## Performance Testing

```bash
# Install performance test tools
sudo apt-get install -y perftest

# Test Soft-RoCE performance
# On server
ib_send_bw -d rxe0

# On client
ib_send_bw -d rxe0 <server-ip>
```

## Troubleshooting

### Issue: No RDMA devices found
```bash
# Check if modules loaded
lsmod | grep rdma

# Reload modules
sudo modprobe -r rdma_rxe
sudo modprobe rdma_rxe

# Recreate rxe device
sudo rdma link delete rxe0
sudo rdma link add rxe0 type rxe netdev eth0
```

### Issue: Cannot create rxe device
```bash
# Check network interface name
ip link show

# Use correct interface (might be ens5 on newer Ubuntu)
sudo rdma link add rxe0 type rxe netdev ens5
```

### Issue: Connection refused
```bash
# Check if server is listening
sudo netstat -tlnp | grep 4433

# Check firewall/security groups
# Ensure ports 4433 and 4791 are open
```

### Issue: Performance issues
```bash
# Check CPU governor
cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor

# Set to performance mode
echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
```

## Cost Optimization

### Development/Testing
- Use **t3.large** spot instances (70% cheaper)
- Stop instances when not in use
- Use AWS Free Tier if eligible

### Spot Instance Launch
```bash
aws ec2 request-spot-instances \
  --spot-price "0.03" \
  --instance-count 1 \
  --type "one-time" \
  --launch-specification file://spot-spec.json
```

### Auto-shutdown Script
```bash
# Add to crontab to auto-shutdown after 2 hours
echo "0 */2 * * * sudo shutdown -h now" | crontab -
```

## Monitoring

```bash
# Monitor RDMA traffic
watch -n 1 'ibv_devinfo -v'

# Monitor system resources
htop

# Check RDMA statistics
cat /sys/class/infiniband/rxe0/ports/1/counters/*
```

## Expected Results

When running the demo, you should see:

```
═══ RESULTS ═══
PSN Values:
  Client  1: PSN 0x2807d5 ↔ Server PSN 0x9f8541
  Client  2: PSN 0xd05b13 ↔ Server PSN 0x3f3c9d
  ...

Message Verification:
  Client 1: ✓ 100×'a' received
  Client 2: ✓ 100×'b' received
  ...

Summary:
  • Clients connected: 10/10
  • PSN uniqueness: 10 unique out of 10
  • Resource: ✓ Shared device context
```

## Additional Resources

- [AWS EC2 Instance Types](https://aws.amazon.com/ec2/instance-types/)
- [Soft-RoCE Documentation](https://github.com/linux-rdma/rdma-core)
- [RDMA Programming Guide](https://www.rdmamojo.com/)
- [Project Documentation](docs/)

## Support

For issues specific to AWS setup, please open an issue with:
- Instance type used
- Ubuntu version
- Error messages
- Output of `ibv_devinfo`

---

**Note**: This guide uses Soft-RoCE (software RDMA) which is suitable for development and testing. For production workloads requiring actual RDMA, consider AWS instances with EFA (Elastic Fabric Adapter) support.