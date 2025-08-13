# Secure RDMA Architecture Diagrams

## System Overview

```mermaid
graph LR
    subgraph "Client Applications"
        C1[Client 1]
        C2[Client 2]
        C3[Client N]
    end
    
    subgraph "Secure Channel"
        TLS[TLS 1.2+<br/>Port 4433]
        PSN[PSN Exchange<br/>Encrypted]
    end
    
    subgraph "RDMA Channel"  
        RDMA[RDMA CM<br/>Port 4791]
        QP[Queue Pairs<br/>with PSN]
    end
    
    subgraph "Server"
        SRV[Multi-threaded<br/>Server]
        POOL[Thread Pool<br/>10 Clients Max]
    end
    
    C1 --> TLS
    C2 --> TLS
    C3 --> TLS
    
    TLS --> PSN
    PSN --> SRV
    
    C1 --> RDMA
    C2 --> RDMA
    C3 --> RDMA
    
    RDMA --> QP
    QP --> POOL
    POOL --> SRV
```

## High-Level Architecture

```mermaid
graph TB
    subgraph "Secure RDMA System"
        subgraph "Server Side"
            SS[Secure RDMA Server<br/>Port 4433 TLS<br/>Port 4791 RDMA]
            SS --> MC[Multi-Client Support<br/>MAX_CLIENTS=10]
            SS --> PSN_S[PSN Generator<br/>Cryptographically Secure]
        end
        
        subgraph "Client Side"
            C1[Client 1]
            C2[Client 2]
            CN[Client N]
            PSN_C[PSN Generator<br/>Per Client]
        end
        
        subgraph "Security Layer"
            TLS[TLS 1.2+ Channel<br/>Certificate-based]
            PSN_EX[PSN Exchange<br/>Encrypted]
        end
        
        C1 -.->|TLS Connect| TLS
        C2 -.->|TLS Connect| TLS
        CN -.->|TLS Connect| TLS
        
        TLS <--> PSN_EX
        PSN_EX <--> SS
        
        C1 -->|RDMA Connect| SS
        C2 -->|RDMA Connect| SS
        CN -->|RDMA Connect| SS
    end
    
    style SS fill:#f9f,stroke:#333,stroke-width:4px
    style TLS fill:#9f9,stroke:#333,stroke-width:2px
    style PSN_EX fill:#ff9,stroke:#333,stroke-width:2px
```

## Mid-Level Component Flow

```mermaid
sequenceDiagram
    participant C as Client
    participant TLS as TLS Channel
    participant S as Server
    participant RDMA as RDMA Channel
    
    Note over C,S: Phase 1 - TLS Connection and PSN Exchange
    
    C->>S: connect_tls_server() Port 4433
    S->>S: accept_tls_connection()
    S-->>C: TLS Session Established
    
    C->>C: generate_secure_psn()
    S->>S: generate_secure_psn()
    
    C->>TLS: exchange_psn_client()
    TLS->>S: Send Client PSN
    S->>TLS: exchange_psn_server()
    TLS-->>C: Send Server PSN
    
    Note over C,S: Phase 2 - RDMA Connection Setup
    
    C->>RDMA: connect_to_server() Port 4791
    RDMA->>S: handle_rdma_connection()
    
    C->>C: setup_qp_with_psn()
    S->>S: setup_qp_with_psn()
    
    Note over C,S: Exchange RDMA Parameters
    C->>TLS: send_rdma_params()
    TLS->>S: receive_rdma_params()
    S->>TLS: send_rdma_params()
    TLS->>C: receive_rdma_params()
    
    S-->>C: RDMA Connection Established
    
    Note over C,S: Phase 3 - Data Operations
    
    loop RDMA Operations
        C->>RDMA: send_message() or rdma_write_to_server()
        RDMA->>S: handle_client_rdma()
        S-->>C: Response via RDMA
    end
```

## Low-Level Detailed Implementation

### Server Thread Architecture

```mermaid
graph TD
    subgraph "Main Process"
        MAIN["main() - Signal Handlers - init_server()"]
        MAIN --> INIT_SSL["init_openssl() - create_server_context() - configure_server_context()"]
        MAIN --> INIT_RDMA["rdma_create_event_channel() - rdma_create_id() - rdma_bind_addr() - rdma_listen()"]
    end
    
    subgraph "TLS Listener Thread"
        TLS_THREAD["tls_listener_thread()"]
        TLS_THREAD --> ACCEPT["accept_tls_connection() - SSL_accept()"]
        ACCEPT --> CREATE_CLIENT["Create client_connection - Allocate resources"]
        CREATE_CLIENT --> SPAWN["pthread_create() - client_handler_thread"]
    end
    
    subgraph "RDMA Listener Thread"
        RDMA_THREAD["rdma_listener_thread()"]
        RDMA_THREAD --> GET_EVENT["rdma_get_cm_event()"]
        GET_EVENT --> HANDLE_CONN["handle_rdma_connection() - rdma_accept()"]
    end
    
    subgraph "Client Handler Thread Pool"
        CLIENT_THREAD["client_handler_thread()"]
        CLIENT_THREAD --> PSN_EXCHANGE["exchange_psn_server() - generate_secure_psn()"]
        PSN_EXCHANGE --> INIT_RES["init_rdma_resources() - ibv_reg_mr()"]
        INIT_RES --> SETUP_QP["setup_qp_with_psn()"]
        SETUP_QP --> QP_STATES["QP: RESET to INIT to RTR to RTS"]
        QP_STATES --> HANDLE_OPS["handle_client_rdma()"]
        HANDLE_OPS --> POLL["ibv_poll_cq() - send_message() - post_receive()"]
    end
    
    MAIN --> TLS_THREAD
    MAIN --> RDMA_THREAD
    TLS_THREAD --> CLIENT_THREAD
```

### Client Connection Flow

```mermaid
graph TD
    subgraph "Client Initialization"
        START["main()"]
        START --> INIT["init_openssl()"]
        INIT --> TLS_CONN["connect_tls_server() - Port 4433"]
    end
    
    subgraph "Security Phase"
        TLS_CONN --> PSN_CLIENT["exchange_psn_client()"]
        PSN_CLIENT --> GEN_PSN["generate_secure_psn() - RAND_bytes()"]
        GEN_PSN --> SEND_PSN["SSL_write(client_psn)"]
        SEND_PSN --> RECV_PSN["SSL_read(server_psn)"]
    end
    
    subgraph "RDMA Setup"
        RECV_PSN --> RDMA_CONN["connect_to_server() - Port 4791"]
        RDMA_CONN --> RESOLVE["rdma_resolve_addr() - rdma_resolve_route()"]
        RESOLVE --> CREATE_QP["rdma_create_qp()"]
        CREATE_QP --> INIT_RESOURCES["init_rdma_resources()"]
        INIT_RESOURCES --> REG_MR["ibv_reg_mr() - send_mr, recv_mr"]
    end
    
    subgraph "QP Configuration"
        REG_MR --> SETUP_PSN["setup_qp_with_psn()"]
        SETUP_PSN --> EXCHANGE_PARAMS["send_rdma_params() - receive_rdma_params()"]
        EXCHANGE_PARAMS --> MOD_QP["ibv_modify_qp()"]
        MOD_QP --> QP_INIT["QP to INIT - qp_access_flags"]
        QP_INIT --> QP_RTR["QP to RTR - rq_psn=remote_psn"]
        QP_RTR --> QP_RTS["QP to RTS - sq_psn=local_psn"]
    end
    
    subgraph "Operations"
        QP_RTS --> RUN["run_interactive_client()"]
        RUN --> OPS{User Command}
        OPS -->|send| SEND_MSG["send_message()"]
        OPS -->|write| RDMA_WRITE["rdma_write_to_server()"]
        OPS -->|auto| AUTO_TEST["Automatic messages"]
        SEND_MSG --> POLL_CQ["ibv_poll_cq()"]
        RDMA_WRITE --> POLL_CQ
        AUTO_TEST --> POLL_CQ
    end
```

### Data Structures and Memory Management

```mermaid
classDiagram
    class server_context {
        +SSL_CTX* ssl_ctx
        +int tls_listen_sock
        +pthread_t tls_thread
        +rdma_event_channel* ec
        +rdma_cm_id* listener
        +pthread_t rdma_thread
        +client_connection* clients[]
        +pthread_mutex_t clients_mutex
        +int num_clients
        +volatile int running
        +init_server()
        +cleanup_server()
    }
    
    class client_connection {
        +int client_id
        +pthread_t thread_id
        +volatile int active
        +tls_connection* tls_conn
        +uint32_t local_psn
        +uint32_t remote_psn
        +rdma_cm_id* cm_id
        +ibv_qp* qp
        +ibv_pd* pd
        +ibv_mr* send_mr
        +ibv_mr* recv_mr
        +char* send_buffer
        +char* recv_buffer
        +rdma_conn_params remote_params
        +init_rdma_resources()
        +setup_qp_with_psn()
        +handle_client_rdma()
    }
    
    class tls_connection {
        +SSL_CTX* ctx
        +SSL* ssl
        +int socket
        +accept_tls_connection()
        +connect_tls_server()
        +close_tls_connection()
    }
    
    class rdma_conn_params {
        +uint32_t qp_num
        +uint16_t lid
        +uint8_t gid[16]
        +uint32_t psn
        +uint32_t rkey
        +uint64_t remote_addr
        +send_rdma_params()
        +receive_rdma_params()
    }
    
    class psn_exchange {
        +uint32_t client_psn
        +uint32_t server_psn
        +generate_secure_psn()
        +exchange_psn_server()
        +exchange_psn_client()
    }
    
    server_context "1" --> "*" client_connection : manages
    client_connection "1" --> "1" tls_connection : uses
    client_connection "1" --> "1" rdma_conn_params : exchanges
    tls_connection "1" --> "1" psn_exchange : performs
```

### Security Flow Detail

```mermaid
flowchart LR
    subgraph "PSN Generation"
        RAND["RAND_bytes - OpenSSL"]
        URD["/dev/urandom - Fallback"]
        TIME["time+pid - Last Resort"]
        
        RAND -->|Success| PSN["24-bit PSN - Non-zero"]
        URD -->|If RAND fails| PSN
        TIME -->|If URD fails| PSN
    end
    
    subgraph "TLS Security"
        CERT[X.509 Certificate]
        KEY[RSA 2048-bit Key]
        TLS12[TLS 1.2+]
        CIPHER[AES-256-GCM]
        
        CERT --> TLS12
        KEY --> TLS12
        TLS12 --> CIPHER
    end
    
    subgraph "PSN Exchange Protocol"
        C_PSN[Client PSN]
        S_PSN[Server PSN]
        
        C_PSN -->|Encrypted| TLS_CH[TLS Channel]
        S_PSN -->|Encrypted| TLS_CH
        TLS_CH --> SECURE[Secure Exchange]
    end
    
    subgraph "RDMA Security"
        PSN --> QP_INIT2["QP Initialization"]
        QP_INIT2 --> RTR["RTR State - rq_psn"]
        QP_INIT2 --> RTS["RTS State - sq_psn"]
        RTR --> REPLAY["Replay Protection"]
        RTS --> ORDER["Packet Ordering"]
    end
```

### Multi-Client Handling

```mermaid
stateDiagram-v2
    [*] --> ServerInit: init_server()
    
    ServerInit --> Listening: Start threads
    
    state Listening {
        TLSListener --> WaitTLS: accept_tls_connection()
        WaitTLS --> ClientAccepted: New client
        ClientAccepted --> AllocateSlot: Find free slot
        AllocateSlot --> CreateThread: pthread_create()
        CreateThread --> TLSListener
        
        RDMAListener --> WaitRDMA: rdma_get_cm_event()
        WaitRDMA --> ConnRequest: CONNECT_REQUEST
        ConnRequest --> MatchClient: Find client by address
        MatchClient --> AcceptRDMA: rdma_accept()
        AcceptRDMA --> RDMAListener
    }
    
    state ClientHandler {
        PSNExchange --> WaitCMID: Wait for RDMA
        WaitCMID --> InitResources: init_rdma_resources()
        InitResources --> SetupQP: setup_qp_with_psn()
        SetupQP --> Operations: handle_client_rdma()
        Operations --> Cleanup: Client disconnect
    }
    
    Listening --> ClientHandler: Per client thread
    ClientHandler --> Listening: Thread complete
    
    Listening --> Shutdown: SIGINT/SIGTERM
    Shutdown --> [*]: cleanup_server()
```

### Error Handling and Resource Management

```mermaid
flowchart TD
    subgraph "Resource Allocation"
        ALLOC[Allocate Resources]
        ALLOC --> MEM[malloc buffers]
        ALLOC --> MR[ibv_reg_mr]
        ALLOC --> QP[Create QP]
        ALLOC --> CQ[Create CQ]
    end
    
    subgraph "Error Detection"
        ERR{Error?}
        ERR -->|SSL Error| SSL_ERR[print_ssl_error]
        ERR -->|RDMA Error| RDMA_ERR[perror/ibv_wc_status_str]
        ERR -->|System Error| SYS_ERR[strerror]
    end
    
    subgraph "Cleanup Path"
        CLEAN[Cleanup Resources]
        CLEAN --> DEREG[ibv_dereg_mr]
        CLEAN --> DISC[rdma_disconnect]
        CLEAN --> DESTROY[rdma_destroy_id]
        CLEAN --> FREE[free buffers]
        CLEAN --> SSL_FREE[SSL_free]
        CLEAN --> CLOSE[close sockets]
    end
    
    subgraph "Thread Safety"
        MUTEX[pthread_mutex]
        MUTEX --> LOCK[Lock clients_mutex]
        LOCK --> MODIFY[Modify client list]
        MODIFY --> UNLOCK[Unlock mutex]
    end
    
    ALLOC --> ERR
    ERR -->|Yes| CLEAN
    ERR -->|No| Normal[Normal Operation]
    Normal --> CLEAN
```

## Key Function Mapping

| Component | High-Level Function | Mid-Level Functions | Low-Level Functions |
|-----------|-------------------|-------------------|-------------------|
| **TLS Setup** | Initialize Security | `init_openssl()` | `SSL_load_error_strings()`, `OpenSSL_add_ssl_algorithms()` |
| **PSN Generation** | Generate PSN | `generate_secure_psn()` | `RAND_bytes()`, `open("/dev/urandom")` |
| **Server Listen** | Start Server | `init_server()` | `create_tls_listener()`, `rdma_listen()` |
| **Client Connect** | Connect Client | `connect_to_server()` | `rdma_resolve_addr()`, `rdma_connect()` |
| **PSN Exchange** | Exchange PSNs | `exchange_psn_server/client()` | `SSL_read()`, `SSL_write()` |
| **QP Setup** | Configure QP | `setup_qp_with_psn()` | `ibv_modify_qp()` |
| **Data Transfer** | Send/Receive | `send_message()` | `ibv_post_send()`, `ibv_poll_cq()` |
| **Multi-Client** | Handle Clients | `client_handler_thread()` | `pthread_create()`, `pthread_mutex_lock()` |
| **Cleanup** | Release Resources | `cleanup_server/client()` | `ibv_dereg_mr()`, `rdma_destroy_id()` |

## Summary

These diagrams illustrate the secure RDMA implementation across three abstraction levels:

- **System Overview**: Shows the dual-channel architecture with TLS for security and RDMA for data
- **High-level**: Overall system architecture with multi-client support and security layers
- **Mid-level**: Detailed protocol flow showing the three phases of connection establishment
- **Low-level**: Implementation details including thread architecture, state machines, and function mappings

The implementation ensures security through:
1. Cryptographically secure PSN generation
2. TLS-encrypted PSN exchange before RDMA connection
3. Per-client isolation with dedicated threads and resources
4. Proper QP configuration with exchanged PSNs for replay protection