# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a secure RDMA (Remote Direct Memory Access) implementation that provides:
- Multi-client server supporting concurrent connections
- TLS-based secure PSN (Packet Sequence Number) exchange
- Support for both real RDMA hardware and Soft-RoCE (software RDMA)
- Mock RDMA implementation for environments without RDMA hardware

## Build Commands

```bash
# Build all components
make all

# Build individual components
make secure_server    # Build the secure RDMA server
make secure_client    # Build the secure RDMA client

# Generate TLS certificates (required for secure communication)
make generate-cert

# Clean build artifacts
make clean

# Run basic test
make test
```

## Testing Commands

```bash
# Run comprehensive test suite (requires RDMA hardware or Soft-RoCE)
cd tests
./comprehensive_rdma_test.sh

# Run multi-client stress test
./multi_client_test.sh

# Run from project root with scripts
./scripts/comprehensive_rdma_test.sh
```

## Development Workflow

### Running the Server and Client

```bash
# Terminal 1: Start the server
./build/secure_server

# Terminal 2: Connect a client
./build/secure_client 127.0.0.1 localhost

# Client commands:
# - send <message>  : Send a message via RDMA
# - write <data>    : Perform RDMA write operation
# - quit            : Disconnect from server
```

### Deployment Scripts

For AWS deployment with Soft-RoCE:
```bash
./scripts/deploy_aws_softrce.sh    # Deploy with Soft-RoCE support
./scripts/aws_rdma_test_suite.sh   # Run AWS-specific tests
```

## Architecture

### Core Components

The codebase implements a client-server RDMA architecture with security features:

1. **TLS-PSN Exchange Protocol**: Before establishing RDMA connections, client and server exchange cryptographically secure PSNs via TLS (port 4433), preventing replay attacks.

2. **Multi-Client Architecture**: Server uses threading to handle up to 10 concurrent clients, each with dedicated Queue Pairs (QPs) and Memory Regions (MRs).

3. **Dual Implementation Support**:
   - Real RDMA: Uses libibverbs and librdmacm for hardware RDMA
   - Mock RDMA: Falls back to TCP sockets when RDMA hardware unavailable (src/mock_rdma.c)

### Key Files

- `src/secure_rdma_server.c`: Multi-threaded server with per-client state management
- `src/secure_rdma_client.c`: Client implementation with TLS handshake
- `src/tls_utils.c/h`: TLS utilities for secure PSN generation and exchange
- `src/rdma_compat.h`: Compatibility layer for RDMA structures
- `src/mock_rdma.c`: Mock implementation for non-RDMA environments

### Connection Flow

1. Client initiates TLS connection to server
2. Both generate random PSNs and exchange them over TLS
3. RDMA connection parameters (GID, QPN, LID) exchanged
4. RDMA Queue Pairs created with agreed PSNs
5. QPs transitioned through INIT→RTR→RTS states
6. RDMA operations (send/recv, write/read) can proceed

## Important Implementation Details

- Server listens on port 4791 for RDMA connections
- TLS uses port 4433 for secure PSN exchange
- Each client connection runs in a separate thread
- Proper cleanup on disconnection to prevent resource leaks
- Uses OpenSSL for TLS and cryptographic random number generation
- Supports both IPv4 and IPv6 addresses

## Security Considerations

- PSNs are generated using cryptographically secure random sources
- TLS certificates required (generated via `make generate-cert`)
- All PSN exchanges happen over encrypted TLS channels
- RDMA connections use the exchanged PSNs to prevent replay attacks