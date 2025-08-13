# Secure RDMA Project

A secure RDMA implementation featuring TLS-based PSN exchange and multi-client support.

## Project Overview

This project implements a secure RDMA communication system that addresses key security concerns in RDMA deployments:

1. **Multi-Client Server**: Supports up to 10 concurrent client connections
2. **Secure PSN Exchange**: Uses TLS 1.2+ for encrypted PSN exchange before RDMA connection
3. **Thread-Safe Architecture**: Proper resource isolation and synchronization
4. **Comprehensive Documentation**: Detailed guides, architecture diagrams, and examples

## Project Structure

```
RDMA-project/
├── src/              # Main secure RDMA implementation
├── examples/         # Basic RDMA examples for learning
├── docs/            # Documentation and design files
├── tests/           # Automated test scripts
├── rdma-core/       # RDMA userspace library (reference)
└── libibverbs/      # Low-level verbs library (reference)
```

See [PROJECT_STRUCTURE.md](PROJECT_STRUCTURE.md) for detailed organization.

## Quick Start

### Prerequisites
Install RDMA development packages:
```bash
# Ubuntu/Debian
sudo apt-get install libibverbs-dev librdmacm-dev

# RHEL/Fedora
sudo yum install libibverbs-devel librdmacm-devel
```

### Building
```bash
make all
```

### Running Examples

1. Check RDMA devices:
```bash
make check-devices
```

2. If no hardware RDMA devices, setup software RDMA:
```bash
make setup-rxe
```

3. Run server:
```bash
make run-server
# Or manually: ./rdma_server 5555
```

4. In another terminal, run client:
```bash
make run-client
# Or manually: ./rdma_client 127.0.0.1 5555
```

## Key Libraries

### 1. RDMA-Core
- **Repository**: https://github.com/linux-rdma/rdma-core
- **Purpose**: Userspace RDMA subsystem components
- **Components**: libibverbs, librdmacm, libibumad

### 2. RDMA-CM (Connection Manager)
- **Documentation**: https://www.ibm.com/docs/en/aix/7.2.0?topic=operations-rdma-cm
- **Purpose**: Transport-neutral connection establishment
- **Key APIs**: rdma_create_id, rdma_connect, rdma_accept

### 3. Libibverbs
- **Documentation**: https://www.ibm.com/docs/en/aix/7.3.0?topic=ofed-libibverbs-library
- **Purpose**: RDMA verbs for hardware access
- **Supports**: InfiniBand, RoCE, iWARP

### 4. GPUDirect (Optional)
- **Repository**: https://github.com/gpudirect/libibverbs
- **Purpose**: GPU memory integration with RDMA

## Programming Flow

1. **Initialize Device**: Open RDMA device and create protection domain
2. **Register Memory**: Register buffers for RDMA operations
3. **Create Queue Pairs**: Setup send/receive queues
4. **Establish Connection**: Use RDMA-CM for connection management
5. **Transfer Data**: Use verbs API for data operations
6. **Cleanup**: Properly release all resources

## Operations Supported

- **Send/Receive**: Traditional message passing
- **RDMA Write**: Direct memory write to remote host
- **RDMA Read**: Direct memory read from remote host
- **Atomic Operations**: Compare-and-swap, fetch-and-add

## Performance Tips

1. Use inline data for small messages (<64 bytes)
2. Batch operations before polling completions
3. Register memory once and reuse
4. Use huge pages for large buffers
5. Pin threads to CPU cores for better cache locality

## Troubleshooting

### No RDMA Devices Found
```bash
# Load kernel modules
sudo modprobe ib_core ib_umad ib_uverbs rdma_cm

# Create software RDMA device
sudo modprobe rdma_rxe
sudo rdma link add rxe0 type rxe netdev eth0
```

### Memory Lock Limits
```bash
# Check current limit
ulimit -l

# Increase limit
echo "* soft memlock unlimited" | sudo tee -a /etc/security/limits.conf
echo "* hard memlock unlimited" | sudo tee -a /etc/security/limits.conf
```

## Additional Resources

- [RDMA Aware Programming Manual](https://docs.nvidia.com/networking/)
- [InfiniBand Architecture Specification](https://www.infinibandta.org/)
- [RDMA Consortium](https://www.rdmaconsortium.org/)

## License

Example code is provided for educational purposes.