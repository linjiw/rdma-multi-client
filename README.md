# Secure RDMA Project

## Project Structure
```
rdma-project/
├── src/                 # Source code
│   ├── secure_rdma_server.c
│   ├── secure_rdma_client.c
│   ├── tls_utils.c
│   └── tls_utils.h
├── build/              # Compiled binaries
│   ├── secure_server
│   └── secure_client
├── docs/               # Documentation
├── scripts/            # Utility scripts
├── tests/              # Test scripts
├── logs/               # Log files
├── examples/           # Example code
├── Makefile           # Build configuration
├── server.crt         # TLS certificate
└── server.key         # TLS private key
```

## Quick Start
```bash
cd rdma-project
make clean && make all
./build/secure_server &
./build/secure_client 127.0.0.1 localhost
```

## Testing
```bash
cd tests
./comprehensive_rdma_test.sh
```
