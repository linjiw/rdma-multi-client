# Implementation Flow - Complete Function Interaction

## Server Startup Flow

```mermaid
flowchart TD
    START[main] --> SIG[Setup signal handlers]
    SIG --> INIT[init_server]
    
    subgraph "init_server"
        I1[calloc server_context]
        I1 --> I2[init_openssl]
        I2 --> I3[create_server_context<br/>SSL_CTX_new]
        I3 --> I4[configure_server_context<br/>Load certificates]
        I4 --> I5[create_tls_listener<br/>Port 4433]
        I5 --> I6[ibv_get_device_list]
        I6 --> I7[ibv_open_device<br/>Shared context]
    end
    
    INIT --> CREATE_TH[pthread_create<br/>tls_listener_thread]
    CREATE_TH --> WAIT[Wait for shutdown]
    
    style I7 fill:#9f9,stroke:#333,stroke-width:4px
```

## TLS Listener Thread Flow

```mermaid
flowchart TD
    TLS_START[tls_listener_thread] --> LOOP{server->running?}
    LOOP -->|Yes| ACCEPT[accept_tls_connection]
    LOOP -->|No| EXIT[Thread exit]
    
    ACCEPT --> CHECK_SLOT{Free slot?}
    CHECK_SLOT -->|No| REJECT[Close connection]
    CHECK_SLOT -->|Yes| ALLOC[Allocate client_connection]
    
    ALLOC --> SETUP[Setup client struct]
    SETUP --> SPAWN[pthread_create<br/>client_handler_thread]
    SPAWN --> DETACH[pthread_detach]
    DETACH --> LOOP
    
    style SPAWN fill:#ff9
```

## Client Handler Thread - Complete Flow

```mermaid
flowchart TD
    CH_START[client_handler_thread] --> PSN_EX[exchange_psn_server]
    
    subgraph "PSN Exchange"
        PSN1[generate_secure_psn<br/>Local PSN]
        PSN2[SSL_write local PSN]
        PSN3[SSL_read remote PSN]
        PSN1 --> PSN2
        PSN2 --> PSN3
    end
    
    PSN_EX --> PSN1
    PSN3 --> CREATE_RES[Create RDMA Resources]
    
    subgraph "RDMA Resource Creation"
        R1[Use shared device_ctx]
        R1 --> R2[ibv_alloc_pd]
        R2 --> R3[ibv_create_cq x2]
        R3 --> R4[ibv_create_qp]
        R4 --> R5[Store in client struct]
    end
    
    CREATE_RES --> R1
    R5 --> INIT_RES[init_rdma_resources]
    
    subgraph "Buffer Setup"
        B1[Allocate send_buffer]
        B2[Allocate recv_buffer]
        B3[ibv_reg_mr send_mr]
        B4[ibv_reg_mr recv_mr]
        B1 --> B3
        B2 --> B4
    end
    
    INIT_RES --> B1
    B4 --> SETUP_QP[setup_qp_with_psn]
    
    subgraph "QP Setup"
        Q1[Exchange RDMA params]
        Q2[modify_qp_to_init]
        Q3[modify_qp_to_rtr<br/>Set remote PSN]
        Q4[modify_qp_to_rts<br/>Set local PSN]
        Q1 --> Q2
        Q2 --> Q3
        Q3 --> Q4
    end
    
    SETUP_QP --> Q1
    Q4 --> HANDLE_OPS[handle_rdma_operations]
    
    subgraph "RDMA Operations"
        O1[Post initial receive]
        O2[Send welcome message]
        O3[Poll loop]
        O4[Process messages]
        O1 --> O2
        O2 --> O3
        O3 --> O4
        O4 --> O3
    end
    
    HANDLE_OPS --> O1
    
    style R1 fill:#9f9
    style Q3 fill:#ff9
    style Q4 fill:#ff9
```

## Detailed PSN Setup Flow

```mermaid
sequenceDiagram
    participant Client
    participant TLS
    participant Server
    participant IB_Device
    
    Note over Client,Server: PSN Generation Phase
    Client->>Client: generate_secure_psn()
    Client->>Client: client_psn = 0x2807d5
    
    Server->>Server: generate_secure_psn()
    Server->>Server: server_psn = 0x9f8541
    
    Note over Client,Server: PSN Exchange via TLS
    Client->>TLS: SSL_write(client_psn)
    Server->>TLS: SSL_write(server_psn)
    TLS->>Server: SSL_read() -> client_psn
    TLS->>Client: SSL_read() -> server_psn
    
    Note over Client,Server: QP Creation with PSNs
    Server->>IB_Device: ibv_create_qp()
    IB_Device-->>Server: QP created (QPN: 83)
    
    Client->>IB_Device: ibv_create_qp()
    IB_Device-->>Client: QP created (QPN: 84)
    
    Note over Client,Server: Parameter Exchange
    Server->>TLS: Send (QPN:83, GID, LID)
    Client->>TLS: Send (QPN:84, GID, LID)
    TLS->>Client: Recv (QPN:83, GID, LID)
    TLS->>Server: Recv (QPN:84, GID, LID)
    
    Note over Server,IB_Device: Server QP Transitions
    Server->>IB_Device: modify_qp INIT
    Server->>IB_Device: modify_qp RTR (rq_psn=0x2807d5)
    Server->>IB_Device: modify_qp RTS (sq_psn=0x9f8541)
    
    Note over Client,IB_Device: Client QP Transitions
    Client->>IB_Device: modify_qp INIT
    Client->>IB_Device: modify_qp RTR (rq_psn=0x9f8541)
    Client->>IB_Device: modify_qp RTS (sq_psn=0x2807d5)
    
    Note over Client,Server: RDMA Ready with Custom PSNs
```

## Message Processing Flow

```mermaid
flowchart TD
    MSG_START[handle_rdma_operations] --> POST_RECV[ibv_post_recv]
    POST_RECV --> SEND_WELCOME[Send welcome message]
    
    SEND_WELCOME --> POLL_LOOP[Start poll loop]
    
    POLL_LOOP --> POLL_RECV[ibv_poll_cq recv_cq]
    POLL_RECV --> CHECK_WC{WC available?}
    
    CHECK_WC -->|No| POLL_LOOP
    CHECK_WC -->|Yes| VERIFY{WC success?}
    
    VERIFY -->|No| ERROR[Log error]
    VERIFY -->|Yes| PROCESS[Process message]
    
    PROCESS --> TYPE{Message type?}
    
    TYPE -->|Data| ECHO[Prepare echo response]
    TYPE -->|Write| HANDLE_WRITE[Handle RDMA write]
    TYPE -->|Quit| SHUTDOWN[Begin shutdown]
    
    ECHO --> POST_SEND[ibv_post_send]
    POST_SEND --> POLL_SEND[ibv_poll_cq send_cq]
    POLL_SEND --> NEXT_RECV[ibv_post_recv]
    NEXT_RECV --> POLL_LOOP
    
    ERROR --> BREAK[Break loop]
    SHUTDOWN --> BREAK
    BREAK --> CLEANUP[Cleanup resources]
```

## Resource Cleanup Flow

```mermaid
flowchart TD
    CLEANUP_START[Client disconnect/error] --> DEREG[Deregister memory]
    
    subgraph "Memory Cleanup"
        M1[ibv_dereg_mr send_mr]
        M2[ibv_dereg_mr recv_mr]
        M3[free send_buffer]
        M4[free recv_buffer]
        M1 --> M2
        M2 --> M3
        M3 --> M4
    end
    
    DEREG --> M1
    M4 --> DESTROY[Destroy RDMA objects]
    
    subgraph "RDMA Cleanup"
        D1[ibv_destroy_qp]
        D2[ibv_destroy_cq send_cq]
        D3[ibv_destroy_cq recv_cq]
        D4[ibv_dealloc_pd]
        D1 --> D2
        D2 --> D3
        D3 --> D4
    end
    
    DESTROY --> D1
    D4 --> TLS_CLOSE[close_tls_connection]
    
    subgraph "TLS Cleanup"
        T1[SSL_shutdown]
        T2[SSL_free]
        T3[close socket]
        T1 --> T2
        T2 --> T3
    end
    
    TLS_CLOSE --> T1
    T3 --> SLOT[Update server state]
    
    subgraph "Server State Update"
        S1[Lock mutex]
        S2[Clear client slot]
        S3[Decrement num_clients]
        S4[Unlock mutex]
        S1 --> S2
        S2 --> S3
        S3 --> S4
    end
    
    SLOT --> S1
    S4 --> FREE[free client struct]
    FREE --> EXIT[Thread exit]
    
    style D4 fill:#ff9
    note right of D4
        Don't close device_ctx!
        It's shared by all clients
    end note
```

## Complete System Interaction

```mermaid
graph TB
    subgraph "Main Thread"
        MAIN[main process]
        SHUTDOWN[shutdown handler]
    end
    
    subgraph "TLS Thread"
        TLS_LISTENER[tls_listener_thread]
        ACCEPT[accept connections]
    end
    
    subgraph "Client Threads 1-10"
        CH1[client_handler 1]
        CH2[client_handler 2]
        CH10[client_handler 10]
    end
    
    subgraph "Shared Resources"
        DEV_CTX[device_context]
        SSL_CTX[SSL_context]
        MUTEX[clients_mutex]
    end
    
    subgraph "Per-Client Resources"
        QP1[QP, CQ, PD, MR]
        QP2[QP, CQ, PD, MR]
        QP10[QP, CQ, PD, MR]
    end
    
    MAIN --> TLS_LISTENER
    TLS_LISTENER --> ACCEPT
    
    ACCEPT --> CH1
    ACCEPT --> CH2
    ACCEPT --> CH10
    
    CH1 --> DEV_CTX
    CH2 --> DEV_CTX
    CH10 --> DEV_CTX
    
    CH1 --> SSL_CTX
    CH2 --> SSL_CTX
    
    CH1 --> MUTEX
    CH2 --> MUTEX
    CH10 --> MUTEX
    
    CH1 --> QP1
    CH2 --> QP2
    CH10 --> QP10
    
    SHUTDOWN --> TLS_LISTENER
    SHUTDOWN --> CH1
    SHUTDOWN --> CH2
    
    style DEV_CTX fill:#9f9,stroke:#333,stroke-width:4px
    style MUTEX fill:#ff9,stroke:#333,stroke-width:4px
```

## Error Recovery Flows

```mermaid
flowchart TD
    ERROR[Error Detected] --> TYPE{Error Type}
    
    TYPE -->|TLS Error| TLS_ERR[SSL_get_error]
    TYPE -->|QP Error| QP_ERR[ibv_query_qp]
    TYPE -->|CQ Error| CQ_ERR[Check WC status]
    TYPE -->|Memory Error| MEM_ERR[errno check]
    
    TLS_ERR --> TLS_ACTION{Recoverable?}
    TLS_ACTION -->|Yes| TLS_RETRY[Retry operation]
    TLS_ACTION -->|No| TLS_CLOSE[Close connection]
    
    QP_ERR --> QP_STATE{QP State?}
    QP_STATE -->|ERROR| QP_RESET[Reset QP]
    QP_STATE -->|Other| QP_LOG[Log state]
    
    CQ_ERR --> WC_STATUS{Status code?}
    WC_STATUS -->|RETRY_EXC| RETRY[Retry send]
    WC_STATUS -->|Other| LOG[Log error]
    
    MEM_ERR --> MEM_ACTION{Type?}
    MEM_ACTION -->|ENOMEM| WAIT[Wait and retry]
    MEM_ACTION -->|Other| ABORT[Abort operation]
    
    TLS_RETRY --> CONTINUE[Continue operation]
    QP_RESET --> RECONNECT[Reconnect client]
    RETRY --> CONTINUE
    WAIT --> CONTINUE
    
    TLS_CLOSE --> CLEANUP[Cleanup flow]
    QP_LOG --> CLEANUP
    LOG --> CLEANUP
    ABORT --> CLEANUP
    RECONNECT --> CLEANUP
```

## Performance Critical Path

```mermaid
graph LR
    subgraph "Hot Path (Per Message)"
        H1[ibv_poll_cq]
        H2[Process data]
        H3[ibv_post_send]
        H4[ibv_poll_cq]
        H5[ibv_post_recv]
        
        H1 -->|~1μs| H2
        H2 -->|~5μs| H3
        H3 -->|~2μs| H4
        H4 -->|~1μs| H5
        H5 -->|~2μs| H1
    end
    
    subgraph "Cold Path (Connection Setup)"
        C1[TLS handshake]
        C2[PSN exchange]
        C3[QP creation]
        C4[State transitions]
        
        C1 -->|~50ms| C2
        C2 -->|~5ms| C3
        C3 -->|~10ms| C4
    end
    
    style H1 fill:#9f9
    style H2 fill:#9f9
    style H3 fill:#9f9
    style C1 fill:#ff9
```

## Next: [Testing and Validation](TESTING_VALIDATION.md)