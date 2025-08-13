terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  required_version = ">= 1.0"
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  description = "AWS region for deployment"
  default     = "us-east-1"
}

variable "instance_type" {
  description = "EC2 instance type"
  default     = "t3.large"
}

variable "key_name" {
  description = "Name of existing EC2 KeyPair"
  type        = string
}

# IMPORTANT: Must use Ubuntu 20.04 with HWE kernel for rdma_rxe module support
# Ubuntu 22.04 has kernel module issues and won't work properly!
data "aws_ami" "ubuntu_2004" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    # Specifically target Ubuntu 20.04 LTS - DO NOT use 22.04!
    values = ["ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Security group for RDMA testing
resource "aws_security_group" "rdma_sg" {
  name        = "rdma-test-sg"
  description = "Security group for RDMA testing with Soft-RoCE"

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "TLS for PSN exchange"
    from_port   = 4433
    to_port     = 4433
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "RDMA port"
    from_port   = 4791
    to_port     = 4791
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow all from same SG"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "rdma-test-sg"
  }
}

# User data script for automatic setup
locals {
  user_data = <<-EOF
    #!/bin/bash
    set -e
    
    # Log all output for debugging
    exec > >(tee -a /var/log/rdma-setup.log)
    exec 2>&1
    
    echo "Starting RDMA setup at $(date)"
    
    # Wait for cloud-init to complete
    cloud-init status --wait
    
    # Verify we're on Ubuntu 20.04
    echo "OS Version Check:"
    lsb_release -a
    
    # Check kernel version (need 5.15.0 or newer for rdma_rxe)
    echo "Kernel Version:"
    uname -r
    
    # Update system
    apt-get update
    
    # CRITICAL: Install HWE kernel for Ubuntu 20.04 if not present
    # This provides kernel 5.15.0 which has rdma_rxe module
    if ! uname -r | grep -q "5.15"; then
      echo "Installing HWE kernel for rdma_rxe support..."
      apt-get install -y linux-generic-hwe-20.04
      echo "HWE kernel installed, reboot required. Rebooting..."
      reboot
    fi
    
    apt-get upgrade -y
    
    # Install dependencies
    apt-get install -y \
      build-essential \
      git \
      libibverbs-dev \
      librdmacm-dev \
      rdma-core \
      ibverbs-utils \
      rdmacm-utils \
      perftest \
      libssl-dev \
      openssl \
      kmod
    
    # Verify kernel modules are available
    echo "Checking for rdma_rxe module..."
    if ! modinfo rdma_rxe &>/dev/null; then
      echo "ERROR: rdma_rxe module not found! This kernel doesn't support Soft-RoCE."
      echo "Please ensure you're using Ubuntu 20.04 with HWE kernel (5.15.0 or newer)"
      exit 1
    fi
    
    # Load RDMA modules
    modprobe rdma_rxe || { echo "Failed to load rdma_rxe"; exit 1; }
    modprobe ib_core
    modprobe rdma_ucm
    
    # Configure Soft-RoCE
    INTERFACE=$(ip route | grep default | awk '{print $5}' | head -1)
    echo "Configuring Soft-RoCE on interface: $INTERFACE"
    rdma link add rxe0 type rxe netdev $INTERFACE || true
    
    # Verify RDMA device created
    echo "RDMA devices:"
    ibv_devices
    
    # Clone and build project
    cd /home/ubuntu
    sudo -u ubuntu git clone https://github.com/linjiw/rmda-multi-client.git
    cd rmda-multi-client
    sudo -u ubuntu make clean && sudo -u ubuntu make all
    sudo -u ubuntu make generate-cert
    
    # Verify build completed
    if [ -f /home/ubuntu/rmda-multi-client/build/secure_server ]; then
      echo "Build successful!"
    else
      echo "Build failed! Check logs."
      exit 1
    fi
    
    # Create systemd service
    cat > /etc/systemd/system/soft-roce.service << 'EOSERVICE'
    [Unit]
    Description=Configure Soft-RoCE
    After=network.target
    
    [Service]
    Type=oneshot
    ExecStart=/bin/bash -c 'rdma link add rxe0 type rxe netdev $(ip route | grep default | awk "{print \$5}" | head -1)'
    RemainAfterExit=yes
    
    [Install]
    WantedBy=multi-user.target
    EOSERVICE
    
    systemctl daemon-reload
    systemctl enable soft-roce.service
    
    # Create completion marker with details
    cat > /home/ubuntu/setup_complete << 'EOSTATUS'
    RDMA Setup Complete!
    
    Kernel: $(uname -r)
    OS: Ubuntu 20.04 LTS
    RDMA Device: rxe0
    Interface: $INTERFACE
    
    To verify:
    - ibv_devices
    - cd ~/rmda-multi-client && ./run_demo_auto.sh
    EOSTATUS
    chown ubuntu:ubuntu /home/ubuntu/setup_complete
    
    echo "Setup complete at $(date)"
  EOF
}

# RDMA Server Instance
resource "aws_instance" "rdma_server" {
  ami           = data.aws_ami.ubuntu_2004.id
  instance_type = var.instance_type
  key_name      = var.key_name
  
  vpc_security_group_ids = [aws_security_group.rdma_sg.id]
  
  user_data = local.user_data
  
  root_block_device {
    volume_type = "gp3"
    volume_size = 20
  }
  
  tags = {
    Name = "RDMA-Server"
    Type = "rdma-test"
  }
}

# RDMA Client Instance (optional)
resource "aws_instance" "rdma_client" {
  count         = var.create_client ? 1 : 0
  ami           = data.aws_ami.ubuntu_2004.id
  instance_type = var.instance_type
  key_name      = var.key_name
  
  vpc_security_group_ids = [aws_security_group.rdma_sg.id]
  
  user_data = local.user_data
  
  root_block_device {
    volume_type = "gp3"
    volume_size = 20
  }
  
  tags = {
    Name = "RDMA-Client"
    Type = "rdma-test"
  }
}

variable "create_client" {
  description = "Create a client instance for testing"
  type        = bool
  default     = false
}

# Outputs
output "server_public_ip" {
  value = aws_instance.rdma_server.public_ip
  description = "Public IP of RDMA server"
}

output "server_private_ip" {
  value = aws_instance.rdma_server.private_ip
  description = "Private IP of RDMA server"
}

output "client_public_ip" {
  value = var.create_client ? aws_instance.rdma_client[0].public_ip : null
  description = "Public IP of RDMA client"
}

output "ssh_command_server" {
  value = "ssh -i ${var.key_name}.pem ubuntu@${aws_instance.rdma_server.public_ip}"
  description = "SSH command to connect to server"
}

output "setup_status" {
  value = "Check if setup is complete: ssh into instance and run 'ls -la ~/setup_complete'"
  description = "Setup completion check"
}