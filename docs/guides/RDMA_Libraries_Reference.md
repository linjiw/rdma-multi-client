# RDMA Libraries Reference Documentation

## Table of Contents
1. [RDMA-Core Library Overview](#rdma-core-library-overview)
2. [RDMA Connection Manager (RDMA-CM)](#rdma-connection-manager-rdma-cm)
3. [Libibverbs Library](#libibverbs-library)
4. [Programming Examples](#programming-examples)
5. [Key Data Structures](#key-data-structures)
6. [Build and Setup](#build-and-setup)

---

## RDMA-Core Library Overview

### Purpose
The rdma-core library provides userspace components for the Linux Kernel's RDMA (Remote Direct Memory Access) subsystem. It enables direct hardware access from userspace for high-performance networking.

### Key Components

#### Core Libraries
1. **libibverbs** - Interface for `/dev/infiniband/uverbsX`
2. **librdmacm** - Interface for `/dev/infiniband/rdma_cm`
3. **libibumad** - Interface for `/dev/infiniband/umadX`

#### Supported Kernel RDMA Drivers
- bnxt_re
- efa
- mlx4_ib
- mlx5_ib
- rdma_rxe
- And many more...

#### Service Daemons
- **srp_daemon** - SCSI RDMA Protocol daemon
- **iwpmd** - iWARP Port Mapper daemon
- **ibacm** - InfiniBand Communication Management Assistant

### Repository Structure
```
rdma-core/
├── providers/      # Hardware-specific providers
├── libibverbs/     # Core verbs library
├── librdmacm/      # Connection manager library
├── tests/          # Test suites
└── Documentation/  # API documentation
```

---

## RDMA Connection Manager (RDMA-CM)

### Overview
RDMA-CM is a communication manager used to set up reliable, connected, and unreliable datagram data transfers. It provides a transport-neutral interface for establishing RDMA connections.

### Key API Functions

#### Connection Management
```c
// Create communication identifier
struct rdma_cm_id *rdma_create_id(struct rdma_event_channel *channel,
                                  void *context,
                                  enum rdma_port_space ps);

// Resolve address
int rdma_resolve_addr(struct rdma_cm_id *id,
                     struct sockaddr *src_addr,
                     struct sockaddr *dst_addr,
                     int timeout_ms);

// Connect (client)
int rdma_connect(struct rdma_cm_id *id,
                struct rdma_conn_param *conn_param);

// Accept connection (server)
int rdma_accept(struct rdma_cm_id *id,
               struct rdma_conn_param *conn_param);
```

#### Data Transfer Operations
```c
// Register memory for messages
struct ibv_mr *rdma_reg_msgs(struct rdma_cm_id *id,
                            void *addr,
                            size_t length);

// Post send operation
int rdma_post_send(struct rdma_cm_id *id,
                  void *context,
                  void *addr,
                  size_t length,
                  struct ibv_mr *mr,
                  int flags);

// Post receive operation
int rdma_post_recv(struct rdma_cm_id *id,
                  void *context,
                  void *addr,
                  size_t length,
                  struct ibv_mr *mr);

// RDMA read
int rdma_post_read(struct rdma_cm_id *id,
                  void *context,
                  void *addr,
                  size_t length,
                  struct ibv_mr *mr,
                  int flags,
                  uint64_t remote_addr,
                  uint32_t rkey);

// RDMA write
int rdma_post_write(struct rdma_cm_id *id,
                   void *context,
                   void *addr,
                   size_t length,
                   struct ibv_mr *mr,
                   int flags,
                   uint64_t remote_addr,
                   uint32_t rkey);
```

### Connection Establishment Flow

#### Client Side
1. Create event channel
2. Create RDMA identifier
3. Resolve address
4. Resolve route
5. Create queue pair
6. Connect
7. Perform data transfers
8. Disconnect

#### Server Side
1. Create event channel
2. Create RDMA identifier
3. Bind to address
4. Listen for connections
5. Accept connection
6. Perform data transfers
7. Disconnect

### Event Handling
Key events:
- `RDMA_CM_EVENT_ADDR_RESOLVED`
- `RDMA_CM_EVENT_ROUTE_RESOLVED`
- `RDMA_CM_EVENT_CONNECT_REQUEST`
- `RDMA_CM_EVENT_ESTABLISHED`
- `RDMA_CM_EVENT_DISCONNECTED`

---

## Libibverbs Library

### Overview
Libibverbs enables user-space processes to use RDMA verbs for direct access to RDMA hardware. It supports multiple technologies:
- InfiniBand
- RDMA over Converged Ethernet (RoCE)
- Internet Wide Area RDMA Protocol (iWARP)

### Programming Flow

#### 1. Device Initialization
```c
// Get device list
struct ibv_device **dev_list = ibv_get_device_list(&num_devices);

// Open device
struct ibv_context *context = ibv_open_device(device);

// Allocate protection domain
struct ibv_pd *pd = ibv_alloc_pd(context);
```

#### 2. Memory Registration
```c
// Register memory region
struct ibv_mr *mr = ibv_reg_mr(pd, buffer, size,
                               IBV_ACCESS_LOCAL_WRITE |
                               IBV_ACCESS_REMOTE_READ |
                               IBV_ACCESS_REMOTE_WRITE);
```

#### 3. Queue Pair Creation
```c
// Create completion queues
struct ibv_cq *send_cq = ibv_create_cq(context, cq_size, NULL, NULL, 0);
struct ibv_cq *recv_cq = ibv_create_cq(context, cq_size, NULL, NULL, 0);

// Define QP attributes
struct ibv_qp_init_attr qp_init_attr = {
    .send_cq = send_cq,
    .recv_cq = recv_cq,
    .cap = {
        .max_send_wr = 10,
        .max_recv_wr = 10,
        .max_send_sge = 1,
        .max_recv_sge = 1,
        .max_inline_data = 0
    },
    .qp_type = IBV_QPT_RC,  // Reliable Connected
};

// Create queue pair
struct ibv_qp *qp = ibv_create_qp(pd, &qp_init_attr);
```

#### 4. Queue Pair State Transitions
```c
// RESET -> INIT
struct ibv_qp_attr attr = {
    .qp_state = IBV_QPS_INIT,
    .pkey_index = 0,
    .port_num = port,
    .qp_access_flags = IBV_ACCESS_LOCAL_WRITE |
                       IBV_ACCESS_REMOTE_READ |
                       IBV_ACCESS_REMOTE_WRITE
};
ibv_modify_qp(qp, &attr, IBV_QP_STATE | IBV_QP_PKEY_INDEX |
              IBV_QP_PORT | IBV_QP_ACCESS_FLAGS);

// INIT -> RTR (Ready to Receive)
attr.qp_state = IBV_QPS_RTR;
attr.path_mtu = IBV_MTU_1024;
attr.dest_qp_num = remote_qpn;
attr.rq_psn = 0;
// Set additional attributes...
ibv_modify_qp(qp, &attr, required_flags);

// RTR -> RTS (Ready to Send)
attr.qp_state = IBV_QPS_RTS;
attr.timeout = 14;
attr.retry_cnt = 7;
attr.rnr_retry = 7;
attr.sq_psn = 0;
attr.max_rd_atomic = 1;
ibv_modify_qp(qp, &attr, required_flags);
```

### Fast-path vs Slow-path Functions

**Slow-path functions** (involve kernel, expensive context switch):
- `ibv_open_device()`
- `ibv_alloc_pd()`
- `ibv_create_qp()`
- `ibv_reg_mr()`

**Fast-path functions** (bypass kernel, high performance):
- `ibv_post_send()`
- `ibv_post_recv()`
- `ibv_poll_cq()`

---

## Programming Examples

### Basic RDMA Send/Receive Example

```c
#include <rdma/rdma_cma.h>
#include <rdma/rdma_verbs.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct rdma_context {
    struct rdma_cm_id *id;
    struct ibv_mr *send_mr;
    struct ibv_mr *recv_mr;
    char *send_buf;
    char *recv_buf;
    size_t msg_length;
};

// Initialize RDMA resources
int init_rdma_resources(struct rdma_context *ctx) {
    // Allocate buffers
    ctx->msg_length = 1024;
    ctx->send_buf = malloc(ctx->msg_length);
    ctx->recv_buf = malloc(ctx->msg_length);
    
    // Register memory regions
    ctx->send_mr = rdma_reg_msgs(ctx->id, ctx->send_buf, ctx->msg_length);
    ctx->recv_mr = rdma_reg_msgs(ctx->id, ctx->recv_buf, ctx->msg_length);
    
    if (!ctx->send_mr || !ctx->recv_mr) {
        fprintf(stderr, "Failed to register memory\n");
        return -1;
    }
    
    return 0;
}

// Post a receive buffer
int post_receive(struct rdma_context *ctx) {
    return rdma_post_recv(ctx->id, NULL, ctx->recv_buf, 
                         ctx->msg_length, ctx->recv_mr);
}

// Send a message
int send_message(struct rdma_context *ctx, const char *message) {
    strcpy(ctx->send_buf, message);
    return rdma_post_send(ctx->id, NULL, ctx->send_buf,
                         ctx->msg_length, ctx->send_mr,
                         IBV_SEND_SIGNALED);
}

// RDMA Write operation
int rdma_write_remote(struct rdma_context *ctx, uint64_t remote_addr, 
                      uint32_t rkey, void *local_data, size_t length) {
    memcpy(ctx->send_buf, local_data, length);
    return rdma_post_write(ctx->id, NULL, ctx->send_buf, length,
                          ctx->send_mr, IBV_SEND_SIGNALED,
                          remote_addr, rkey);
}

// RDMA Read operation
int rdma_read_remote(struct rdma_context *ctx, uint64_t remote_addr,
                     uint32_t rkey, size_t length) {
    return rdma_post_read(ctx->id, NULL, ctx->recv_buf, length,
                         ctx->recv_mr, IBV_SEND_SIGNALED,
                         remote_addr, rkey);
}

// Poll for completion
int wait_for_completion(struct rdma_context *ctx) {
    struct ibv_wc wc;
    int ret;
    
    while ((ret = ibv_poll_cq(ctx->id->send_cq, 1, &wc)) == 0) {
        // Busy wait
    }
    
    if (ret < 0) {
        fprintf(stderr, "Poll CQ failed\n");
        return -1;
    }
    
    if (wc.status != IBV_WC_SUCCESS) {
        fprintf(stderr, "Work completion failed: %s\n",
                ibv_wc_status_str(wc.status));
        return -1;
    }
    
    return 0;
}
```

### Server Connection Setup

```c
int setup_server(struct rdma_context *ctx, const char *port) {
    struct rdma_event_channel *ec;
    struct rdma_cm_id *listener;
    struct rdma_cm_event *event;
    struct sockaddr_in addr;
    
    // Create event channel
    ec = rdma_create_event_channel();
    if (!ec) {
        fprintf(stderr, "Failed to create event channel\n");
        return -1;
    }
    
    // Create listener
    if (rdma_create_id(ec, &listener, NULL, RDMA_PS_TCP)) {
        fprintf(stderr, "Failed to create CM ID\n");
        return -1;
    }
    
    // Bind to address
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(atoi(port));
    
    if (rdma_bind_addr(listener, (struct sockaddr *)&addr)) {
        fprintf(stderr, "Failed to bind address\n");
        return -1;
    }
    
    // Listen for connections
    if (rdma_listen(listener, 10)) {
        fprintf(stderr, "Failed to listen\n");
        return -1;
    }
    
    // Wait for connection request
    if (rdma_get_cm_event(ec, &event)) {
        fprintf(stderr, "Failed to get CM event\n");
        return -1;
    }
    
    if (event->event != RDMA_CM_EVENT_CONNECT_REQUEST) {
        fprintf(stderr, "Unexpected event: %s\n",
                rdma_event_str(event->event));
        return -1;
    }
    
    ctx->id = event->id;
    rdma_ack_cm_event(event);
    
    // Initialize resources and accept connection
    init_rdma_resources(ctx);
    
    struct rdma_conn_param conn_param = {
        .initiator_depth = 1,
        .responder_resources = 1,
    };
    
    if (rdma_accept(ctx->id, &conn_param)) {
        fprintf(stderr, "Failed to accept connection\n");
        return -1;
    }
    
    return 0;
}
```

### Client Connection Setup

```c
int setup_client(struct rdma_context *ctx, const char *server_addr, 
                 const char *port) {
    struct rdma_event_channel *ec;
    struct sockaddr_in addr;
    struct rdma_conn_param conn_param;
    
    // Create event channel
    ec = rdma_create_event_channel();
    if (!ec) {
        fprintf(stderr, "Failed to create event channel\n");
        return -1;
    }
    
    // Create CM ID
    if (rdma_create_id(ec, &ctx->id, NULL, RDMA_PS_TCP)) {
        fprintf(stderr, "Failed to create CM ID\n");
        return -1;
    }
    
    // Resolve address
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = inet_addr(server_addr);
    addr.sin_port = htons(atoi(port));
    
    if (rdma_resolve_addr(ctx->id, NULL, 
                         (struct sockaddr *)&addr, 2000)) {
        fprintf(stderr, "Failed to resolve address\n");
        return -1;
    }
    
    // Wait for address resolution
    // ... (event handling code)
    
    // Resolve route
    if (rdma_resolve_route(ctx->id, 2000)) {
        fprintf(stderr, "Failed to resolve route\n");
        return -1;
    }
    
    // Wait for route resolution
    // ... (event handling code)
    
    // Initialize resources
    init_rdma_resources(ctx);
    
    // Connect
    memset(&conn_param, 0, sizeof(conn_param));
    conn_param.initiator_depth = 1;
    conn_param.responder_resources = 1;
    conn_param.retry_count = 7;
    
    if (rdma_connect(ctx->id, &conn_param)) {
        fprintf(stderr, "Failed to connect\n");
        return -1;
    }
    
    // Wait for connection establishment
    // ... (event handling code)
    
    return 0;
}
```

---

## Key Data Structures

### rdma_cm_id
Primary identifier for RDMA connections, similar to a socket:
```c
struct rdma_cm_id {
    struct ibv_context *verbs;    // Verbs context
    struct rdma_event_channel *channel;  // Event channel
    void *context;                // User context
    struct ibv_qp *qp;           // Queue pair
    struct rdma_route route;      // Routing information
    enum rdma_port_space ps;      // Port space (TCP/UDP/IB)
    uint8_t port_num;            // Port number
};
```

### ibv_qp_init_attr
Queue pair initialization attributes:
```c
struct ibv_qp_init_attr {
    void *qp_context;
    struct ibv_cq *send_cq;      // Send completion queue
    struct ibv_cq *recv_cq;      // Receive completion queue
    struct ibv_srq *srq;         // Shared receive queue (optional)
    struct ibv_qp_cap cap;       // QP capabilities
    enum ibv_qp_type qp_type;    // QP type (RC, UC, UD)
    int sq_sig_all;              // Signal all send requests
};

struct ibv_qp_cap {
    uint32_t max_send_wr;        // Max outstanding send requests
    uint32_t max_recv_wr;        // Max outstanding receive requests
    uint32_t max_send_sge;       // Max scatter/gather elements (send)
    uint32_t max_recv_sge;       // Max scatter/gather elements (recv)
    uint32_t max_inline_data;    // Max inline data size
};
```

### ibv_mr
Memory region descriptor:
```c
struct ibv_mr {
    struct ibv_context *context;
    struct ibv_pd *pd;           // Protection domain
    void *addr;                  // Start address
    size_t length;               // Length of memory region
    uint32_t handle;            // Handle
    uint32_t lkey;              // Local key
    uint32_t rkey;              // Remote key
};
```

### ibv_wc
Work completion structure:
```c
struct ibv_wc {
    uint64_t wr_id;             // Work request ID
    enum ibv_wc_status status;   // Completion status
    enum ibv_wc_opcode opcode;   // Operation type
    uint32_t vendor_err;        // Vendor error code
    uint32_t byte_len;          // Number of bytes transferred
    uint32_t imm_data;          // Immediate data
    uint32_t qp_num;            // QP number
    uint32_t src_qp;            // Source QP (for UD)
    int wc_flags;               // Completion flags
    uint16_t pkey_index;        // P_Key index
    uint16_t slid;              // Source LID
    uint8_t sl;                 // Service level
    uint8_t dlid_path_bits;     // DLID path bits
};
```

---

## Build and Setup

### Building rdma-core

#### Prerequisites (Ubuntu/Debian)
```bash
sudo apt-get install build-essential cmake gcc libudev-dev \
    libnl-3-dev libnl-route-3-dev ninja-build pkg-config \
    valgrind python3-dev cython3 python3-docutils pandoc
```

#### Prerequisites (RHEL/Fedora)
```bash
sudo yum install cmake gcc libnl3-devel libudev-devel \
    make pkgconfig valgrind-devel ninja-build \
    python3-devel python3-Cython python3-docutils pandoc
```

#### Build Steps
```bash
# Clone repository
git clone https://github.com/linux-rdma/rdma-core.git
cd rdma-core

# Build
bash build.sh

# Or manual build
mkdir build
cd build
cmake -GNinja ..
ninja

# Install (optional)
sudo ninja install
```

### System Configuration

#### Memory Locking Limits
Check current limit:
```bash
ulimit -l
```

Increase limit for user in `/etc/security/limits.conf`:
```
username    hard    memlock    unlimited
username    soft    memlock    unlimited
```

#### Kernel Module Loading
```bash
# Load RDMA modules
sudo modprobe ib_core
sudo modprobe ib_umad
sudo modprobe ib_uverbs
sudo modprobe rdma_cm
sudo modprobe rdma_ucm

# For specific hardware (example: Mellanox)
sudo modprobe mlx5_core
sudo modprobe mlx5_ib
```

#### Verify RDMA Setup
```bash
# Check loaded modules
lsmod | grep -E 'rdma|ib_'

# List RDMA devices
ibv_devices

# Show device information
ibv_devinfo

# Check RDMA links
rdma link show
```

### Creating RDMA Devices

#### Software RDMA (RXE)
```bash
# Load RXE module
sudo modprobe rdma_rxe

# Add RXE device
sudo rdma link add rxe0 type rxe netdev eth0

# Verify
rdma link show
```

---

## Error Handling Best Practices

### Return Code Checking
```c
#define CHECK_ERR(call, msg) \
    do { \
        if ((call) < 0) { \
            fprintf(stderr, "%s failed: %s (errno=%d)\n", \
                    msg, strerror(errno), errno); \
            return -1; \
        } \
    } while(0)

// Usage
CHECK_ERR(rdma_connect(id, &param), "rdma_connect");
```

### Completion Status Verification
```c
const char* wc_status_str(enum ibv_wc_status status) {
    switch(status) {
        case IBV_WC_SUCCESS: return "SUCCESS";
        case IBV_WC_LOC_LEN_ERR: return "LOCAL_LENGTH_ERROR";
        case IBV_WC_LOC_QP_OP_ERR: return "LOCAL_QP_OPERATION_ERROR";
        case IBV_WC_LOC_PROT_ERR: return "LOCAL_PROTECTION_ERROR";
        case IBV_WC_WR_FLUSH_ERR: return "WORK_REQUEST_FLUSHED_ERROR";
        case IBV_WC_MW_BIND_ERR: return "MEMORY_WINDOW_BIND_ERROR";
        case IBV_WC_BAD_RESP_ERR: return "BAD_RESPONSE_ERROR";
        case IBV_WC_LOC_ACCESS_ERR: return "LOCAL_ACCESS_ERROR";
        case IBV_WC_REM_INV_REQ_ERR: return "REMOTE_INVALID_REQUEST_ERROR";
        case IBV_WC_REM_ACCESS_ERR: return "REMOTE_ACCESS_ERROR";
        case IBV_WC_REM_OP_ERR: return "REMOTE_OPERATION_ERROR";
        case IBV_WC_RETRY_EXC_ERR: return "RETRY_EXCEEDED_ERROR";
        case IBV_WC_RNR_RETRY_EXC_ERR: return "RNR_RETRY_EXCEEDED_ERROR";
        default: return "UNKNOWN_ERROR";
    }
}
```

### Resource Cleanup
```c
void cleanup_rdma_resources(struct rdma_context *ctx) {
    if (ctx->send_mr) rdma_dereg_mr(ctx->send_mr);
    if (ctx->recv_mr) rdma_dereg_mr(ctx->recv_mr);
    if (ctx->send_buf) free(ctx->send_buf);
    if (ctx->recv_buf) free(ctx->recv_buf);
    if (ctx->id) {
        rdma_disconnect(ctx->id);
        rdma_destroy_id(ctx->id);
    }
}
```

---

## Performance Optimization Tips

1. **Use Inline Data**: For small messages (<= 64 bytes typically), use inline data to avoid memory registration overhead.

2. **Batch Operations**: Post multiple work requests before polling for completions.

3. **Polling vs Blocking**: Use busy polling for low latency, event notification for CPU efficiency.

4. **Memory Registration**: Register memory once and reuse; avoid frequent registration/deregistration.

5. **Completion Queue Management**: Size CQs appropriately; too small causes overflow, too large wastes memory.

6. **CPU Affinity**: Pin RDMA threads to specific CPU cores for better cache locality.

7. **Huge Pages**: Use huge pages for large memory registrations to reduce TLB misses.

---

## References

- [RDMA-Core GitHub Repository](https://github.com/linux-rdma/rdma-core)
- [IBM AIX RDMA Documentation](https://www.ibm.com/docs/en/aix/)
- [NVIDIA RDMA Programming Guide](https://docs.nvidia.com/networking/)
- [InfiniBand Architecture Specification](https://www.infinibandta.org/)
- [RDMA Consortium Specifications](https://www.rdmaconsortium.org/)