# Terraform Deployment for RDMA Testing on AWS

This Terraform configuration automatically deploys AWS EC2 instances configured for RDMA testing with Soft-RoCE.

## Prerequisites

1. [Terraform](https://www.terraform.io/downloads) installed (>= 1.0)
2. AWS CLI configured with credentials
3. An existing AWS key pair for SSH access

## Quick Start

1. **Initialize Terraform**:
```bash
cd terraform
terraform init
```

2. **Create variables file**:
```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your settings
```

3. **Review the plan**:
```bash
terraform plan
```

4. **Deploy**:
```bash
terraform apply
```

5. **Get connection info**:
```bash
terraform output
```

## Configuration Options

| Variable | Description | Default |
|----------|-------------|---------|
| `aws_region` | AWS region to deploy in | us-east-1 |
| `instance_type` | EC2 instance type | t3.large |
| `key_name` | Your AWS key pair name | (required) |
| `create_client` | Create client instance too | false |

## What Gets Deployed

### Single Instance Mode (default)
- 1 EC2 instance (server)
- Security group with RDMA ports
- Automatic Soft-RoCE setup
- Project cloned and built

### Dual Instance Mode (`create_client = true`)
- 2 EC2 instances (server + client)
- Both configured identically
- Can test client-server communication

## Accessing Instances

After deployment:

```bash
# Get SSH command
terraform output ssh_command_server

# SSH to server
ssh -i your-key.pem ubuntu@<server-ip>

# Check if setup is complete
ls -la ~/setup_complete

# Run demo
cd ~/rdma-multi-client
./run_demo_auto.sh
```

## Testing Between Instances

If you created both server and client:

1. **On Server**:
```bash
cd ~/rdma-multi-client
./build/secure_server
```

2. **On Client**:
```bash
# Get server private IP from terraform output
cd ~/rdma-multi-client
./build/secure_client <server-private-ip> <server-private-ip>
```

## Cost Estimation

- **t3.large**: ~$0.0832/hour
- **Storage**: 20GB gp3 = ~$1.60/month
- **Data transfer**: Minimal for testing

**Monthly estimate** (24/7): ~$60/instance

## Cleanup

To destroy all resources:
```bash
terraform destroy
```

## Troubleshooting

### Check setup logs
```bash
# On instance
sudo tail -f /var/log/cloud-init-output.log
```

### Verify Soft-RoCE
```bash
ibv_devices
```

### Check project build
```bash
cd ~/rdma-multi-client
ls -la build/
```

## Advanced Usage

### Using Spot Instances
Add to instance resource:
```hcl
instance_market_options {
  market_type = "spot"
  spot_options {
    max_price = "0.04"
  }
}
```

### Custom VPC
Modify the configuration to use existing VPC/subnet:
```hcl
subnet_id = "subnet-xxxxxxxx"
```

## Security Notes

- Security group allows SSH from anywhere (0.0.0.0/0)
- Restrict SSH access in production
- RDMA ports are open to all - restrict as needed