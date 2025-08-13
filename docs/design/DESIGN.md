# Secure RDMA Server and Client Design

## Requirements Analysis

### Requirement 1: Multi-Client Support
- **Requirement**: One server can connect to multiple clients at the same time
- **Implementation Strategy**:
  - Use threading or epoll for handling multiple concurrent connections
  - Maintain a connection pool with per-client state
  - Each client gets dedicated QP (Queue Pair) and memory regions
  - Server uses a listener thread and worker threads for clients

### Requirement 2: Secure PSN Exchange
- **Requirement**: Server and client both generate random PSN and exchange via TLS
- **Implementation Strategy**:
  - Use OpenSSL for TLS implementation
  - Generate cryptographically secure random PSN using /dev/urandom or OpenSSL RAND
  - Exchange PSN during TLS handshake before RDMA connection setup
  - Use PSN to initialize RDMA QP for replay attack protection

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                     RDMA Server                          │
├─────────────────────────────────────────────────────────┤
│  TLS Listener (Port 4433)  │  RDMA Listener (Port 4791) │
├─────────────────────────────────────────────────────────┤
│              Connection Manager Thread Pool              │
├─────────────────────────────────────────────────────────┤
│  Client 1  │  Client 2  │  Client 3  │  ...  Client N  │
│  ┌──────┐  │  ┌──────┐  │  ┌──────┐  │       ┌──────┐  │
│  │ TLS  │  │  │ TLS  │  │  │ TLS  │  │       │ TLS  │  │
│  │ PSN  │  │  │ PSN  │  │  │ PSN  │  │       │ PSN  │  │
│  │  QP  │  │  │  QP  │  │  │  QP  │  │       │  QP  │  │
│  │  MR  │  │  │  MR  │  │  │  MR  │  │       │  MR  │  │
│  └──────┘  │  └──────┘  │  └──────┘  │       └──────┘  │
└─────────────────────────────────────────────────────────┘
```

## Security Flow

### Connection Establishment Sequence

1. **TLS Handshake Phase**
   ```
   Client                          Server
     |                               |
     |------ TLS Connect -------->   |
     |<----- TLS Accept ----------   |
     |                               |
     |------ Generate PSN -------    |
     |       Generate PSN --------   |
     |                               |
     |------ Send Client PSN ---->   |
     |<----- Send Server PSN -----   |
     |                               |
     |------ Exchange RDMA Info -->  |
     |       (GID, QPN, LID)         |
     |<----- Exchange RDMA Info ---  |
     |                               |
   ```

2. **RDMA Connection Phase**
   ```
   Client                          Server
     |                               |
     |------ Create QP with PSN -->  |
     |<----- Create QP with PSN ---  |
     |                               |
     |------ Modify QP to RTR ---->  |
     |<----- Modify QP to RTR -----  |
     |                               |
     |------ Modify QP to RTS ---->  |
     |<----- Modify QP to RTS -----  |
     |                               |
     |====== RDMA Operations ======  |
   ```

## Key Data Structures

### Client Connection Structure
```c
struct client_connection {
    // TLS Components
    SSL *ssl;
    int tls_socket;
    
    // RDMA Components
    struct rdma_cm_id *cm_id;
    struct ibv_qp *qp;
    struct ibv_mr *send_mr;
    struct ibv_mr *recv_mr;
    
    // Security
    uint32_t local_psn;
    uint32_t remote_psn;
    
    // Connection Info
    struct rdma_conn_info {
        uint32_t qp_num;
        uint16_t lid;
        uint8_t gid[16];
        uint32_t psn;
    } local_info, remote_info;
    
    // Thread Management
    pthread_t thread_id;
    int client_id;
    volatile int active;
};
```

### Server Connection Pool
```c
struct server_context {
    // TLS Server
    SSL_CTX *ssl_ctx;
    int tls_listen_socket;
    
    // RDMA Server
    struct rdma_event_channel *ec;
    struct rdma_cm_id *listener;
    
    // Client Management
    struct client_connection *clients[MAX_CLIENTS];
    pthread_mutex_t clients_mutex;
    int num_clients;
    
    // Server State
    volatile int running;
};
```

## Implementation Components

### 1. TLS Module (`tls_utils.c`)
- Initialize OpenSSL
- Create TLS server/client contexts
- Handle certificates and keys
- Secure PSN generation and exchange

### 2. RDMA Security Module (`rdma_security.c`)
- PSN generation using secure random
- QP initialization with PSN
- Connection parameter validation

### 3. Multi-Client Manager (`connection_manager.c`)
- Thread pool for client handling
- Connection lifecycle management
- Resource allocation and cleanup

### 4. Secure RDMA Server (`secure_rdma_server.c`)
- Main server implementation
- TLS listener thread
- RDMA listener thread
- Client worker threads

### 5. Secure RDMA Client (`secure_rdma_client.c`)
- TLS connection establishment
- PSN exchange
- RDMA connection with security

## Security Considerations

### PSN (Packet Sequence Number) Security
- **Purpose**: Prevent replay attacks and ensure packet ordering
- **Generation**: Use cryptographically secure random (32-bit)
- **Exchange**: Over authenticated TLS channel
- **Validation**: Verify PSN in QP attributes

### TLS Configuration
- **Protocol**: TLS 1.2 or higher
- **Cipher Suites**: Use strong ciphers (AES-256-GCM)
- **Certificates**: Support both self-signed (dev) and CA-signed (prod)
- **Mutual Authentication**: Optional client certificates

### Memory Protection
- **Memory Registration**: Only register necessary buffers
- **Access Control**: Use appropriate access flags
- **Cleanup**: Deregister memory on disconnect

### Connection Security
- **Rate Limiting**: Limit connection attempts
- **Timeout**: Implement connection timeouts
- **Resource Limits**: Cap maximum clients

## Error Handling

### Connection Failures
- TLS handshake failures
- RDMA connection failures
- PSN mismatch errors
- Resource exhaustion

### Runtime Errors
- Memory registration failures
- QP state transition errors
- Network disconnections
- Thread synchronization issues

## Testing Strategy

### Unit Tests
- PSN generation randomness
- TLS connection establishment
- RDMA operations

### Integration Tests
- Multi-client connections
- Concurrent operations
- Failure recovery

### Security Tests
- PSN uniqueness
- TLS security validation
- Resource leak detection

## Build Configuration

### Dependencies
- OpenSSL (>= 1.1.1)
- libibverbs
- librdmacm
- pthread

### Compilation Flags
```makefile
CFLAGS = -Wall -Wextra -O2 -D_GNU_SOURCE
LDFLAGS = -lssl -lcrypto -libverbs -lrdmacm -lpthread
```

## Performance Optimizations

### Threading Model
- One thread per client (initial implementation)
- Future: Thread pool with epoll

### Memory Management
- Pre-allocated buffer pools
- Reusable memory regions
- Efficient cleanup

### RDMA Optimizations
- Inline data for small messages
- Batch operations
- Selective signaling