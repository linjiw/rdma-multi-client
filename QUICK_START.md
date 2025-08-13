# Quick Start Guide

## Prerequisites

```bash
# Install required packages
sudo apt-get update
sudo apt-get install -y build-essential libibverbs-dev librdmacm-dev libssl-dev

# Setup Soft-RoCE (if no RDMA hardware)
sudo modprobe rdma_rxe
sudo rdma link add rxe0 type rxe netdev eth0

# Verify RDMA device
ibv_devices
```

## Build

```bash
# Clone the repository
git clone https://github.com/linjiw/rmda-multi-client.git
cd rmda-multi-client

# Build all components
make clean && make all

# Generate TLS certificates
make generate-cert
```

## Run the Demo

### Option 1: Automated Demo (Recommended)
```bash
# Run complete demo with 10 clients
./run_demo_auto.sh
```

Expected output:
```
═══ RESULTS ═══
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

### Option 2: Manual Server and Client

Terminal 1 - Start Server:
```bash
./build/secure_server
```

Terminal 2 - Connect Client:
```bash
./build/secure_client 127.0.0.1 localhost

# Client commands:
send Hello from client
write Test RDMA write
quit
```

## Test Suite

```bash
# Run multi-client test
./test_multi_client.sh

# Run thread safety test
./test_thread_safety.sh

# Basic test
make test
```

## Troubleshooting

### No RDMA devices found
```bash
# Check if Soft-RoCE is loaded
lsmod | grep rdma_rxe

# Re-add Soft-RoCE device
sudo rdma link delete rxe0
sudo rdma link add rxe0 type rxe netdev eth0
```

### Port already in use
```bash
# Check what's using the port
sudo lsof -i :4433

# Clean up all processes
./demo_cleanup.sh
```

### Certificate errors
```bash
# Regenerate certificates
rm -f server.key server.crt
make generate-cert
```

## Documentation

- [Architecture Overview](docs/ARCHITECTURE_OVERVIEW.md)
- [Security Design](docs/SECURITY_DESIGN.md)
- [Implementation Flow](docs/IMPLEMENTATION_FLOW.md)
- [Testing & Validation](docs/TESTING_VALIDATION.md)

## Key Features Demonstrated

✅ **Secure PSN Exchange**: TLS-protected PSN generation and exchange
✅ **Pure IB Verbs**: Full control over QP state transitions
✅ **Multi-Client**: 10 concurrent clients with thread safety
✅ **Resource Optimization**: Shared device context
✅ **Replay Prevention**: Unique PSN per connection