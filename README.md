# Secure RDMA with Pure IB Verbs Implementation

## Overview

This project implements a secure RDMA (Remote Direct Memory Access) server-client architecture using pure InfiniBand verbs, with TLS-based secure PSN (Packet Sequence Number) exchange. The implementation provides full control over PSN values to prevent replay attacks while supporting multiple concurrent clients.

## Key Features

- **Pure IB Verbs**: Direct control over QP state transitions and PSN values
- **Secure PSN Exchange**: TLS-based cryptographically secure PSN generation and exchange
- **Multi-Client Support**: Handles up to 10 concurrent clients (configurable)
- **Shared Device Context**: Optimized resource usage with single device context
- **Thread-Safe**: Verified concurrent client handling with stress testing
- **Soft-RoCE Support**: Works with both hardware RDMA and software RDMA

## Architecture

### Connection Flow

1. Client initiates TLS connection to server (port 4433)
2. Both generate cryptographically secure random PSNs
3. PSNs exchanged over encrypted TLS channel
4. RDMA parameters (GID, QPN, LID) exchanged
5. Queue Pairs created with custom PSN values
6. QPs transitioned through INIT→RTR→RTS states
7. RDMA operations proceed with secure PSNs

### Resource Management

- **Server**: Opens device context once, shared by all clients
- **Per-Client**: Separate PD, QP, CQs, and Memory Regions
- **Thread Model**: Dedicated thread per client connection
- **Cleanup**: Proper resource deallocation on disconnect

## Project Structure
```
rmda-multi-client/
├── src/                        # Source code
│   ├── secure_rdma_server.c   # Multi-client server (pure IB verbs)
│   ├── secure_rdma_client.c   # Client implementation
│   ├── tls_utils.c/h         # TLS and PSN utilities
│   └── rdma_compat.h         # RDMA compatibility layer
├── build/                     # Compiled binaries
│   ├── secure_server
│   └── secure_client
├── docs/                      # Documentation
│   ├── PURE_IB_VERBS_DESIGN.md
│   ├── IMPLEMENTATION_LOG.md
│   └── MULTI_CLIENT_ANALYSIS.md
├── scripts/                   # Utility scripts
├── tests/                     # Test scripts
│   ├── test_pure_ib.c
│   ├── test_multi_client.sh
│   └── test_thread_safety.sh
├── logs/                      # Log files
├── Makefile                   # Build configuration
├── server.crt                 # TLS certificate
└── server.key                 # TLS private key
```

## Quick Start

### AWS Setup (Recommended)
For running on AWS EC2 with Soft-RoCE:
```bash
# Use Ubuntu 20.04/22.04 on t3.large instance
wget https://raw.githubusercontent.com/linjiw/rmda-multi-client/main/scripts/aws_quick_setup.sh
chmod +x aws_quick_setup.sh
./aws_quick_setup.sh
```
See [AWS_SETUP.md](AWS_SETUP.md) for detailed AWS configuration.

### Clone Repository
```bash
git clone https://github.com/linjiw/rmda-multi-client.git
cd rmda-multi-client
```

### Prerequisites
```bash
# Install required packages
sudo apt-get install -y libibverbs-dev librdmacm-dev libssl-dev

# Configure Soft-RoCE (if no hardware RDMA)
sudo modprobe rdma_rxe
sudo rdma link add rxe0 type rxe netdev eth0
```

### Building
```bash
# Build all components
make clean && make all

# Generate TLS certificates (if not present)
make generate-cert
```

### Running

#### Start Server
```bash
./build/secure_server
```

#### Connect Client
```bash
./build/secure_client 127.0.0.1 localhost
```

#### Client Commands
- `send <message>` - Send message via RDMA
- `write <data>` - Perform RDMA write operation
- `quit` - Disconnect from server

## Testing

### Basic Functionality Test
```bash
make test
```

### Multi-Client Test
```bash
# Tests 13 clients in various patterns
./test_multi_client.sh
```

### Thread Safety Verification
```bash
# Stress tests with simultaneous connections
./test_thread_safety.sh
```

### Comprehensive Test Suite
```bash
cd tests
./comprehensive_rdma_test.sh
```

## Implementation Details

### Why Pure IB Verbs?

The original RDMA CM (Connection Manager) implementation had a critical limitation: `rdma_accept()` and `rdma_connect()` automatically transition QPs to RTS state, preventing custom PSN control. By using pure IB verbs, we gain:

- Full control over QP state transitions
- Ability to set custom PSN values
- Direct device and resource management
- Better understanding of RDMA internals

### Security Features

- **Cryptographic PSN Generation**: Uses OpenSSL's secure random number generator
- **TLS Protection**: All parameter exchanges happen over TLS (port 4433)
- **PSN Uniqueness**: Each connection gets unique PSN values
- **Replay Prevention**: Custom PSNs prevent replay attacks

### Performance Characteristics

- Supports 10 concurrent clients (MAX_CLIENTS)
- Shared device context reduces resource usage
- No detected memory leaks
- Clean shutdown and resource cleanup
- Thread-safe with mutex protection

## Configuration

Key parameters in `src/secure_rdma_server.c`:
- `MAX_CLIENTS`: Maximum concurrent clients (default: 10)
- `RDMA_PORT`: RDMA listening port (default: 4791)
- `TLS_PORT`: TLS listening port (default: 4433)
- `BUFFER_SIZE`: Message buffer size (default: 4096)

## Test Results Summary

### Multi-Client Test
- 10/13 clients connected successfully (MAX_CLIENTS limit)
- All PSN values unique
- Server stability confirmed

### Thread Safety Test
- 10 truly simultaneous connections handled
- 0 race conditions detected
- 0 thread safety issues
- Mutex protection verified

## Known Limitations

1. Fixed maximum client limit (MAX_CLIENTS = 10)
2. No automatic reconnection logic
3. Basic error recovery mechanisms
4. No configuration file support (hardcoded values)

## Troubleshooting

### AWS Kernel Module Issues
**CRITICAL**: Not all AWS instances/kernels support Soft-RoCE!

```bash
# Check kernel version (need 5.15.0 or newer)
uname -r

# Check if rdma_rxe module exists
modinfo rdma_rxe

# If missing on Ubuntu 20.04, install HWE kernel:
sudo apt-get update
sudo apt-get install -y linux-generic-hwe-20.04
sudo reboot

# If on Ubuntu 22.04 and having issues, switch to Ubuntu 20.04
```

### No RDMA Devices Found
```bash
# Check RDMA devices
ibv_devices

# Check if modules loaded
lsmod | grep rdma

# Configure Soft-RoCE if needed
sudo modprobe rdma_rxe
sudo rdma link add rxe0 type rxe netdev eth0
```

### Certificate Errors
```bash
# Generate new certificates
make generate-cert
```

### Connection Failures
```bash
# Check if ports are available
netstat -an | grep -E "4433|4791"

# Check server logs
tail -f server.log
```

### Build Errors
```bash
# Install dependencies
sudo apt-get install -y build-essential libibverbs-dev librdmacm-dev libssl-dev
```

### AWS Instance Selection
- **Working**: t3.large with Ubuntu 20.04 + HWE kernel (5.15.0-139-generic)
- **Issues**: Ubuntu 22.04 (kernel module compatibility issues)
- **Solution**: Use Ubuntu 20.04 LTS AMI with HWE kernel

## Future Improvements

1. Dynamic client allocation (remove MAX_CLIENTS limit)
2. Connection retry logic with exponential backoff
3. Enhanced monitoring and metrics collection
4. Configuration file support (YAML/JSON)
5. Performance optimizations for high throughput
6. Docker containerization
7. Kubernetes deployment manifests
8. Prometheus metrics endpoint

## AWS Deployment

### Quick AWS Setup
```bash
# Use t3.large Ubuntu 20.04/22.04 instance
wget https://raw.githubusercontent.com/linjiw/rmda-multi-client/main/scripts/aws_quick_setup.sh
bash aws_quick_setup.sh
```

### Terraform Deployment
```bash
cd terraform
terraform init
terraform apply -var="key_name=your-key"
```

See [AWS_SETUP.md](AWS_SETUP.md) for detailed AWS instructions.

## Documentation

- [AWS Setup Guide](AWS_SETUP.md) - Complete AWS EC2 configuration
- [Pure IB Verbs Design](docs/PURE_IB_VERBS_DESIGN.md) - Architecture and design decisions
- [Implementation Log](IMPLEMENTATION_LOG.md) - Development progress and findings
- [Multi-Client Analysis](MULTI_CLIENT_ANALYSIS.md) - Concurrent client handling analysis
- [Quick Start Guide](QUICK_START.md) - Getting started quickly
- [CLAUDE.md](CLAUDE.md) - AI assistant instructions and project context

## License

This project is for educational and research purposes.

## Acknowledgments

Developed as part of RDMA security research, focusing on secure PSN exchange and pure IB verbs implementation to prevent replay attacks in RDMA communications.