# Secure RDMA Server and Client Implementation Guide

## Overview

This implementation provides a secure RDMA communication system that meets the following requirements:

1. **Multi-Client Support**: One server can connect to multiple clients simultaneously
2. **Secure PSN Exchange**: Server and client generate random PSNs and exchange them via TLS

## Architecture

### Security Features

- **TLS 1.2+ Encryption**: All PSN exchanges happen over encrypted TLS channels
- **Cryptographically Secure PSN**: Using OpenSSL RAND for PSN generation
- **Per-Connection Security**: Each client gets unique PSN pair
- **Multi-threaded Server**: Handles multiple clients concurrently

### Component Overview

```
┌─────────────────────────────────────────┐
│           Secure RDMA Server            │
├─────────────────────────────────────────┤
│  TLS Listener Thread (Port 4433)        │
│  - Accept TLS connections                │
│  - PSN exchange                          │
│  - Certificate validation                │
├─────────────────────────────────────────┤
│  RDMA Listener Thread (Port 4791)       │
│  - Accept RDMA connections               │
│  - QP management                         │
│  - Connection state tracking             │
├─────────────────────────────────────────┤
│  Client Handler Threads (1 per client)  │
│  - Individual client management          │
│  - RDMA operations                       │
│  - Resource cleanup                      │
└─────────────────────────────────────────┘
```

## Building the Project

### Prerequisites

1. **Install Dependencies**:
```bash
# Ubuntu/Debian
sudo apt-get install libibverbs-dev librdmacm-dev libssl-dev

# RHEL/Fedora
sudo yum install libibverbs-devel librdmacm-devel openssl-devel
```

2. **Setup RDMA Device** (if no hardware RDMA):
```bash
# Load software RDMA module
sudo modprobe rdma_rxe

# Create software RDMA device on network interface
sudo rdma link add rxe0 type rxe netdev eth0
# Or for loopback testing:
sudo rdma link add rxe0 type rxe netdev lo
```

### Compilation

```bash
# Build all components
make all

# Build only secure components
make secure_server secure_client

# Generate TLS certificate for testing
make generate-cert
```

## Running the System

### Start the Server

```bash
# Run the secure RDMA server
./secure_server

# Or using make
make run-secure-server
```

The server will:
- Listen on port 4433 for TLS connections
- Listen on port 4791 for RDMA connections
- Support up to 10 concurrent clients

### Connect Clients

```bash
# Connect a client
./secure_client <server_ip> <server_hostname>

# Example for localhost
./secure_client 127.0.0.1 localhost

# Example for remote server
./secure_client 192.168.1.100 server.example.com
```

### Client Commands

Once connected, the client supports interactive commands:

- `send <message>` - Send a message to the server
- `write <message>` - Perform RDMA write to server memory
- `auto` - Send 5 automatic test messages
- `quit` - Disconnect and exit

## Testing

### Automated Testing

Run the comprehensive test script:

```bash
# Run as root for software RDMA setup
sudo ./test_secure_rdma.sh

# Or if RDMA devices are already configured
./test_secure_rdma.sh
```

The test script will:
1. Build the secure server and client
2. Generate TLS certificates
3. Start the server
4. Connect multiple clients
5. Verify PSN uniqueness
6. Test concurrent operations

### Manual Testing

#### Test 1: Single Client
```bash
# Terminal 1: Start server
./secure_server

# Terminal 2: Connect client
./secure_client 127.0.0.1 localhost
> send Hello from secure client
> quit
```

#### Test 2: Multiple Clients
```bash
# Terminal 1: Start server
./secure_server

# Terminal 2: First client
./secure_client 127.0.0.1 localhost

# Terminal 3: Second client
./secure_client 127.0.0.1 localhost

# Terminal 4: Third client
./secure_client 127.0.0.1 localhost
```

## Security Details

### PSN Generation

The PSN (Packet Sequence Number) is generated using:

1. **Primary Method**: OpenSSL RAND_bytes() - cryptographically secure
2. **Fallback**: /dev/urandom - system random source
3. **Format**: 24-bit value (masked to 0x00FFFFFF)

```c
uint32_t generate_secure_psn(void) {
    uint32_t psn;
    RAND_bytes((unsigned char*)&psn, sizeof(psn));
    psn = (psn & 0x00FFFFFF) | 0x00000001;  // Ensure non-zero
    return psn;
}
```

### TLS Configuration

- **Minimum Version**: TLS 1.2
- **Cipher Suites**: ECDHE-RSA-AES256-GCM-SHA384, ECDHE-RSA-AES128-GCM-SHA256
- **Certificate**: X.509 self-signed (for testing) or CA-signed (production)

### Connection Flow

1. **TLS Handshake**
   - Client connects to server's TLS port
   - TLS session established with encryption

2. **PSN Exchange**
   - Client generates random PSN, sends to server
   - Server generates random PSN, sends to client
   - Both sides now have secure PSN pair

3. **RDMA Parameter Exchange**
   - Exchange QP numbers, LIDs, GIDs
   - Exchange memory region keys and addresses

4. **RDMA Connection**
   - Client connects to server's RDMA port
   - QPs configured with exchanged PSNs
   - Secure RDMA channel established

## Troubleshooting

### Common Issues

#### 1. No RDMA Devices Found
```bash
# Check for RDMA devices
ibv_devices

# If none found, setup software RDMA
sudo modprobe rdma_rxe
sudo rdma link add rxe0 type rxe netdev lo
```

#### 2. TLS Certificate Issues
```bash
# Regenerate certificate
rm -f server.crt server.key
make generate-cert
```

#### 3. Connection Refused
- Check firewall settings for ports 4433 and 4791
- Verify server is running
- Check server logs for errors

#### 4. Memory Registration Failed
```bash
# Increase memory lock limits
ulimit -l unlimited

# Or permanently in /etc/security/limits.conf
* soft memlock unlimited
* hard memlock unlimited
```

### Debug Output

Enable verbose logging by modifying the source:
```c
#define DEBUG 1  // Add at top of files
```

Check server status:
```bash
# View active connections
ps aux | grep secure_server

# Monitor network connections
netstat -an | grep -E "4433|4791"
```

## Performance Considerations

### Optimizations

1. **Thread Pool**: Current implementation uses one thread per client
2. **Memory Pre-allocation**: Buffers allocated once per connection
3. **Selective Signaling**: Use IBV_SEND_SIGNALED for completion notification
4. **PSN Caching**: PSNs generated once per connection

### Scaling

- **Maximum Clients**: Currently set to 10 (MAX_CLIENTS)
- **Buffer Size**: 4KB per client (configurable)
- **Thread Limit**: System-dependent, typically ~1000 threads

To increase client limit, modify in `secure_rdma_server.c`:
```c
#define MAX_CLIENTS 100  // Increase as needed
```

## API Reference

### TLS Utilities (tls_utils.h)

```c
// Initialize OpenSSL
int init_openssl(void);

// Generate secure PSN
uint32_t generate_secure_psn(void);

// Exchange PSN (server side)
int exchange_psn_server(struct tls_connection *conn, 
                       uint32_t *local_psn, 
                       uint32_t *remote_psn);

// Exchange PSN (client side)
int exchange_psn_client(struct tls_connection *conn,
                       uint32_t *local_psn,
                       uint32_t *remote_psn);
```

### Connection Management

```c
// Client connection structure
struct client_connection {
    int client_id;
    struct tls_connection *tls_conn;
    uint32_t local_psn;
    uint32_t remote_psn;
    struct rdma_cm_id *cm_id;
    // ... RDMA resources
};

// Server context
struct server_context {
    struct client_connection *clients[MAX_CLIENTS];
    int num_clients;
    // ... server resources
};
```

## Compliance with Requirements

### Requirement 1: Multi-Client Support ✓

- Server uses thread pool architecture
- Each client gets dedicated handler thread
- Supports up to MAX_CLIENTS concurrent connections
- Thread-safe client management with mutex protection

### Requirement 2: Secure PSN Exchange ✓

- PSN generated using cryptographically secure random
- Exchange happens over TLS encrypted channel
- Each connection gets unique PSN pair
- PSNs used to initialize RDMA QP security

## Future Enhancements

1. **Persistent Connections**: Implement connection pooling
2. **Load Balancing**: Distribute clients across multiple threads
3. **Monitoring**: Add metrics and health checks
4. **Authentication**: Add client certificate validation
5. **Configuration**: External config file for parameters
6. **Logging**: Structured logging with levels

## License

This implementation is provided for educational purposes.

## Support

For issues or questions:
1. Check the troubleshooting section
2. Review server and client logs
3. Verify RDMA device configuration
4. Ensure TLS certificates are valid