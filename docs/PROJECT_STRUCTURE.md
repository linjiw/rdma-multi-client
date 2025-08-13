# Project Structure

## Directory Layout

```
RDMA-project/
├── src/                      # Main source code
│   ├── secure_rdma_server.c  # Multi-client secure RDMA server
│   ├── secure_rdma_client.c  # Secure RDMA client
│   ├── tls_utils.c           # TLS utilities implementation
│   └── tls_utils.h           # TLS utilities header
│
├── examples/                 # Example implementations
│   ├── rdma_server_example.c # Basic RDMA server example
│   └── rdma_client_example.c # Basic RDMA client example
│
├── docs/                     # Documentation
│   ├── design/              # Design documents
│   │   ├── DESIGN.md        # Architecture and design decisions
│   │   └── architecture_diagrams.md  # Mermaid diagrams
│   │
│   ├── guides/              # User guides
│   │   ├── SECURE_RDMA_GUIDE.md      # Secure RDMA implementation guide
│   │   └── RDMA_Libraries_Reference.md # RDMA libraries reference
│   │
│   └── external/            # External documentation
│       └── gemini_*.md      # Gemini-generated designs
│
├── tests/                    # Test scripts
│   └── test_secure_rdma.sh  # Automated test script
│
├── scripts/                  # Utility scripts
│   └── (future scripts)
│
├── rdma-core/               # RDMA core library (cloned, no git)
├── libibverbs/              # Libibverbs library (cloned, no git)
│
├── Makefile                 # Build configuration
├── README.md                # Project overview
├── requirements.md          # Project requirements
└── PROJECT_STRUCTURE.md    # This file

```

## File Descriptions

### Source Code (`src/`)
- **secure_rdma_server.c**: Main server implementation with multi-client support and TLS-based PSN exchange
- **secure_rdma_client.c**: Client implementation with secure connection establishment
- **tls_utils.c/h**: TLS utilities for secure PSN generation and exchange

### Examples (`examples/`)
- Basic RDMA client/server implementations for learning and reference

### Documentation (`docs/`)
- **design/**: Architecture decisions, design patterns, and visual diagrams
- **guides/**: Implementation guides, API references, and usage instructions
- **external/**: Third-party or auto-generated documentation

### Tests (`tests/`)
- Automated test scripts for validating the secure RDMA implementation

### Libraries
- **rdma-core/**: Complete RDMA userspace library
- **libibverbs/**: Low-level RDMA verbs library

## Building the Project

```bash
# Build secure components
make secure_server secure_client

# Build examples
make rdma_server rdma_client

# Build everything
make all
```

## Running Tests

```bash
# Run automated tests
./tests/test_secure_rdma.sh

# Manual testing
make run-secure-server  # Terminal 1
make run-secure-client  # Terminal 2
```

## Key Features

1. **Security**: TLS-based PSN exchange before RDMA connection
2. **Multi-Client**: Server supports up to 10 concurrent clients
3. **Thread Safety**: Proper synchronization and resource management
4. **Error Handling**: Comprehensive error checking and cleanup
5. **Documentation**: Detailed guides and architecture diagrams