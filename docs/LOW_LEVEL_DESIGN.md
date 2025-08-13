# Low-Level Design - Implementation Details

## Core Data Structures

```mermaid
classDiagram
    class server_context {
        +SSL_CTX* ssl_ctx
        +int tls_listen_sock
        +pthread_t tls_thread
        +ibv_device** dev_list
        +int num_devices
        +ibv_context* device_ctx
        +client_connection* clients[10]
        +pthread_mutex_t clients_mutex
        +int num_clients
        +volatile int running
    }
    
    class client_connection {
        +int client_id
        +pthread_t thread_id
        +volatile int active
        +tls_connection* tls_conn
        +uint32_t local_psn
        +uint32_t remote_psn
        +ibv_context* ctx
        +ibv_qp* qp
        +ibv_pd* pd
        +ibv_cq* send_cq
        +ibv_cq* recv_cq
        +ibv_mr* send_mr
        +ibv_mr* recv_mr
        +char* send_buffer
        +char* recv_buffer
        +rdma_conn_params remote_params
        +server_context* server
    }
    
    class rdma_conn_params {
        +uint32_t qp_num
        +uint16_t lid
        +uint8_t gid[16]
        +uint32_t psn
    }
    
    class tls_connection {
        +int socket
        +SSL* ssl
        +SSL_CTX* ctx
    }
    
    server_context "1" --> "*" client_connection : manages
    client_connection "1" --> "1" tls_connection : uses
    client_connection "1" --> "1" rdma_conn_params : stores
    server_context "1" --> "1" ibv_context : shares
```

## Function Call Flow

### Server Initialization

```mermaid
flowchart TD
    main[main] --> init_server[init_server]
    init_server --> init_openssl[init_openssl]
    init_server --> create_server_context[create_server_context]
    init_server --> configure_server_context[configure_server_context]
    init_server --> create_tls_listener[create_tls_listener]
    init_server --> ibv_get_device_list[ibv_get_device_list]
    init_server --> ibv_open_device[ibv_open_device]
    
    main --> pthread_create_tls[pthread_create: tls_listener_thread]
    
    style ibv_open_device fill:#9f9
```

### Client Connection Flow

```mermaid
flowchart TD
    tls_listener[tls_listener_thread] --> accept_tls[accept_tls_connection]
    accept_tls --> find_slot[Find free client slot]
    find_slot --> pthread_create[pthread_create: client_handler_thread]
    
    subgraph "client_handler_thread"
        CH1[Start] --> PSN[exchange_psn_server]
        PSN --> GEN[generate_secure_psn]
        PSN --> SEND[Send/Recv PSNs via TLS]
        
        SEND --> CREATE_PD[ibv_alloc_pd]
        CREATE_PD --> CREATE_CQ[ibv_create_cq x2]
        CREATE_CQ --> CREATE_QP[ibv_create_qp]
        
        CREATE_QP --> INIT_RES[init_rdma_resources]
        INIT_RES --> REG_MR[ibv_reg_mr x2]
        
        REG_MR --> SETUP_QP[setup_qp_with_psn]
        SETUP_QP --> EXCHANGE[Exchange RDMA params]
        EXCHANGE --> TRANS[QP State Transitions]
        
        TRANS --> OPS[handle_rdma_operations]
        OPS --> POLL[Poll CQs]
        POLL --> SEND_RECV[Process Send/Recv]
    end
    
    style CREATE_QP fill:#9f9
    style GEN fill:#f9f
```

### QP State Transition Detail

```mermaid
stateDiagram-v2
    [*] --> RESET: ibv_create_qp
    RESET --> INIT: modify_qp_to_init()
    
    INIT --> RTR: modify_qp_to_rtr()
    note right of RTR
        Set remote PSN here!
        attr.rq_psn = remote_psn
    end note
    
    RTR --> RTS: modify_qp_to_rts()
    note right of RTS
        Set local PSN here!
        attr.sq_psn = local_psn
    end note
    
    RTS --> ACTIVE: Ready for RDMA
    ACTIVE --> ERROR: On failure
    ERROR --> RESET: Recovery
```

## PSN Exchange Protocol

```mermaid
flowchart LR
    subgraph "Server Side"
        S1[generate_secure_psn] --> S2[server_psn]
        S2 --> S3[SSL_write: server_psn]
        S4[SSL_read: client_psn] --> S5[store client_psn]
    end
    
    subgraph "Client Side"
        C1[generate_secure_psn] --> C2[client_psn]
        C2 --> C3[SSL_write: client_psn]
        C4[SSL_read: server_psn] --> C5[store server_psn]
    end
    
    S3 -.TLS.-> C4
    C3 -.TLS.-> S4
    
    style S1 fill:#f9f
    style C1 fill:#f9f
```

## Memory Registration and Buffer Management

```mermaid
flowchart TB
    subgraph "Per-Client Memory"
        BUF1[Allocate send_buffer<br/>4096 bytes]
        BUF2[Allocate recv_buffer<br/>4096 bytes]
        
        REG1[ibv_reg_mr send_mr<br/>IBV_ACCESS_LOCAL_WRITE]
        REG2[ibv_reg_mr recv_mr<br/>IBV_ACCESS_LOCAL_WRITE<br/>IBV_ACCESS_REMOTE_WRITE]
        
        BUF1 --> REG1
        BUF2 --> REG2
    end
    
    subgraph "RDMA Operations"
        POST_RECV[ibv_post_recv<br/>Uses recv_mr]
        POST_SEND[ibv_post_send<br/>Uses send_mr]
    end
    
    REG2 --> POST_RECV
    REG1 --> POST_SEND
```

## Critical Functions Implementation

### 1. generate_secure_psn()
```c
uint32_t generate_secure_psn() {
    uint32_t psn;
    // Try OpenSSL first
    if (RAND_bytes(&psn, sizeof(psn)) == 1) {
        return psn & 0xFFFFFF;  // 24-bit PSN
    }
    // Fallback to /dev/urandom
    int fd = open("/dev/urandom", O_RDONLY);
    read(fd, &psn, sizeof(psn));
    close(fd);
    return psn & 0xFFFFFF;
}
```

### 2. setup_qp_with_psn()
```mermaid
flowchart TD
    A[setup_qp_with_psn] --> B[Pack local RDMA params]
    B --> C[Send via TLS]
    C --> D[Receive remote params]
    D --> E[modify_qp_to_init]
    E --> F[modify_qp_to_rtr]
    F --> G[Set rq_psn = remote_psn]
    G --> H[modify_qp_to_rts]
    H --> I[Set sq_psn = local_psn]
    I --> J[QP Ready]
    
    style G fill:#9f9
    style I fill:#9f9
```

### 3. handle_rdma_operations()
```mermaid
flowchart TD
    START[Start Loop] --> POST[Post Receive]
    POST --> POLL_RECV[Poll recv_cq]
    
    POLL_RECV --> CHECK{WC Success?}
    CHECK -->|Yes| PROCESS[Process Message]
    CHECK -->|No| ERROR[Handle Error]
    
    PROCESS --> ECHO[Prepare Echo]
    ECHO --> SEND[Post Send]
    SEND --> POLL_SEND[Poll send_cq]
    
    POLL_SEND --> COMPLETE{Complete?}
    COMPLETE -->|Yes| START
    COMPLETE -->|No| RETRY[Retry]
    
    ERROR --> BREAK[Break Loop]
```

## Thread Safety Mechanisms

```mermaid
flowchart LR
    subgraph "Protected by Mutex"
        SLOTS[clients array]
        COUNT[num_clients]
        ALLOC[Slot allocation]
        FREE[Slot freeing]
    end
    
    subgraph "Thread-Local"
        QP[Queue Pairs]
        MR[Memory Regions]
        BUF[Buffers]
    end
    
    subgraph "Shared Read-Only"
        DEV[device_ctx]
        SSL[ssl_ctx]
    end
    
    T1[Thread 1] -->|lock| MUTEX
    T2[Thread 2] -->|lock| MUTEX
    TN[Thread N] -->|lock| MUTEX
    
    MUTEX --> SLOTS
    
    T1 --> QP
    T2 --> MR
    TN --> BUF
    
    T1 --> DEV
    T2 --> DEV
    TN --> DEV
    
    style MUTEX fill:#ff9
    style DEV fill:#9f9
```

## Error Handling Flow

```mermaid
flowchart TD
    OP[RDMA Operation] --> ERR{Error?}
    ERR -->|No| CONT[Continue]
    ERR -->|Yes| TYPE{Error Type}
    
    TYPE -->|QP Error| QP_ERR[Query QP State]
    TYPE -->|CQ Error| CQ_ERR[Check WC Status]
    TYPE -->|Memory| MEM_ERR[Cleanup Resources]
    TYPE -->|Network| NET_ERR[Close Connection]
    
    QP_ERR --> LOG1[Log Error]
    CQ_ERR --> LOG2[Log Status]
    MEM_ERR --> FREE[Free Memory]
    NET_ERR --> CLOSE[Close Socket]
    
    LOG1 --> CLEANUP
    LOG2 --> CLEANUP
    FREE --> CLEANUP
    CLOSE --> CLEANUP
    
    CLEANUP[cleanup_client] --> EXIT[Thread Exit]
```

## Resource Cleanup Sequence

```mermaid
flowchart TD
    DISCONNECT[Client Disconnect] --> DEREG_MR[ibv_dereg_mr x2]
    DEREG_MR --> DESTROY_QP[ibv_destroy_qp]
    DESTROY_QP --> DESTROY_CQ[ibv_destroy_cq x2]
    DESTROY_CQ --> DEALLOC_PD[ibv_dealloc_pd]
    DEALLOC_PD --> FREE_BUF[free buffers]
    FREE_BUF --> CLOSE_TLS[close_tls_connection]
    CLOSE_TLS --> UPDATE_SLOT[Clear client slot]
    UPDATE_SLOT --> DEC_COUNT[Decrement num_clients]
    
    style DEALLOC_PD fill:#f99
    note right of DEALLOC_PD
        Don't close device_ctx!
        It's shared
    end note
```

## Performance Optimizations

```mermaid
graph TB
    subgraph "Optimization 1: Shared Device Context"
        O1[Single ibv_open_device] --> O1R[90% memory reduction]
    end
    
    subgraph "Optimization 2: Pre-allocated Buffers"
        O2[4KB fixed buffers] --> O2R[No dynamic allocation]
    end
    
    subgraph "Optimization 3: Completion Queue Polling"
        O3[Non-blocking poll] --> O3R[Low latency]
    end
    
    subgraph "Optimization 4: Thread Pool (Future)"
        O4[Reuse threads] --> O4R[Reduce creation overhead]
    end
    
    style O1 fill:#9f9
    style O2 fill:#9f9
    style O3 fill:#9f9
    style O4 fill:#ff9
```

## Configuration Parameters

| Parameter | Value | Location | Purpose |
|-----------|-------|----------|---------|
| MAX_CLIENTS | 10 | secure_rdma_server.c:21 | Maximum concurrent clients |
| BUFFER_SIZE | 4096 | secure_rdma_server.c:23 | Message buffer size |
| TLS_PORT | 4433 | tls_utils.h:14 | TLS listener port |
| RDMA_PORT | 4791 | secure_rdma_server.c:22 | RDMA port (unused with pure IB) |
| TIMEOUT_MS | 5000 | secure_rdma_server.c:24 | Operation timeout |
| PSN_MASK | 0xFFFFFF | tls_utils.c | 24-bit PSN space |

## Next: [Security Design](SECURITY_DESIGN.md)