# Architecture Overview - Secure RDMA with Pure IB Verbs

## High-Level Architecture

```mermaid
graph TB
    subgraph "Client Applications (1-10)"
        C1[Client 1<br/>Pattern: 'aaa']
        C2[Client 2<br/>Pattern: 'bbb']
        C3[Client N<br/>Pattern: 'nnn']
    end
    
    subgraph "Security Layer"
        TLS[TLS Server<br/>Port 4433]
        PSN[PSN Exchange<br/>Protocol]
    end
    
    subgraph "RDMA Layer - Pure IB Verbs"
        DEV[Shared Device Context<br/>ibv_open_device]
        QP[Queue Pairs<br/>Management]
        MR[Memory Regions<br/>per Client]
    end
    
    subgraph "Server Core"
        MAIN[Main Thread]
        TH1[Client Handler 1]
        TH2[Client Handler 2]
        THN[Client Handler N]
    end
    
    C1 -->|TLS Connect| TLS
    C2 -->|TLS Connect| TLS
    C3 -->|TLS Connect| TLS
    
    TLS -->|Secure PSN| PSN
    PSN -->|Custom PSN| QP
    
    DEV -->|Shared Context| QP
    QP -->|Per-Client QP| TH1
    QP -->|Per-Client QP| TH2
    QP -->|Per-Client QP| THN
    
    MAIN -->|spawn| TH1
    MAIN -->|spawn| TH2
    MAIN -->|spawn| THN
    
    style TLS fill:#f9f,stroke:#333,stroke-width:4px
    style PSN fill:#f9f,stroke:#333,stroke-width:4px
    style DEV fill:#9f9,stroke:#333,stroke-width:4px
```

## System Components

### 1. Security Layer
- **TLS Server**: Listens on port 4433 for secure connections
- **PSN Exchange Protocol**: Cryptographically secure PSN generation and exchange
- **Certificate Management**: Self-signed or CA certificates for TLS

### 2. RDMA Layer (Pure IB Verbs)
- **Device Management**: Single shared device context for efficiency
- **Queue Pair Control**: Manual QP creation and state transitions
- **Memory Registration**: Per-client memory regions for isolation

### 3. Server Core
- **Multi-threaded Architecture**: Dedicated thread per client
- **Resource Management**: Thread-safe client slot allocation
- **Connection Lifecycle**: Clean connection establishment and teardown

## Key Design Decisions

### Why Pure IB Verbs?

```mermaid
graph LR
    subgraph "RDMA CM Approach (Problem)"
        CM1[rdma_connect]
        CM2[rdma_accept]
        CM3[Auto QP→RTS]
        CM4[No PSN Control]
        
        CM1 --> CM3
        CM2 --> CM3
        CM3 --> CM4
        style CM4 fill:#f99,stroke:#333,stroke-width:2px
    end
    
    subgraph "Pure IB Verbs (Solution)"
        IB1[ibv_create_qp]
        IB2[Manual INIT]
        IB3[Set PSN in RTR]
        IB4[Manual RTS]
        IB5[Full Control]
        
        IB1 --> IB2
        IB2 --> IB3
        IB3 --> IB4
        IB4 --> IB5
        style IB5 fill:#9f9,stroke:#333,stroke-width:2px
    end
```

### Shared Device Context Optimization

```mermaid
graph TB
    subgraph "Before (Inefficient)"
        S1[Server]
        D1[Device 1]
        D2[Device 2]
        D3[Device N]
        
        S1 -->|open| D1
        S1 -->|open| D2
        S1 -->|open| D3
        
        style D1 fill:#faa
        style D2 fill:#faa
        style D3 fill:#faa
    end
    
    subgraph "After (Optimized)"
        S2[Server]
        SD[Shared Device]
        C1[Client 1 PD]
        C2[Client 2 PD]
        CN[Client N PD]
        
        S2 -->|open once| SD
        SD --> C1
        SD --> C2
        SD --> CN
        
        style SD fill:#afa
    end
```

## Connection Flow Sequence

```mermaid
sequenceDiagram
    participant Client
    participant TLS_Server
    participant PSN_Gen
    participant RDMA_Server
    participant IB_Device
    
    Client->>TLS_Server: SSL Connect (4433)
    TLS_Server->>PSN_Gen: Generate Server PSN
    PSN_Gen-->>TLS_Server: 0x9f8541
    
    Client->>PSN_Gen: Generate Client PSN
    PSN_Gen-->>Client: 0x2807d5
    
    Client->>TLS_Server: Send Client PSN
    TLS_Server->>Client: Send Server PSN
    
    Note over Client,TLS_Server: PSN Exchange Complete
    
    TLS_Server->>RDMA_Server: Create QP with PSNs
    RDMA_Server->>IB_Device: ibv_create_qp()
    IB_Device-->>RDMA_Server: QP Created
    
    RDMA_Server->>IB_Device: Transition INIT
    RDMA_Server->>IB_Device: Transition RTR (set remote PSN)
    RDMA_Server->>IB_Device: Transition RTS (set local PSN)
    
    Note over RDMA_Server,IB_Device: QP Ready with Custom PSNs
    
    Client->>RDMA_Server: RDMA Operations
    RDMA_Server->>Client: RDMA Responses
```

## Thread Model

```mermaid
graph TB
    subgraph "Main Process"
        MAIN[main()]
        INIT[init_server()]
        TLS_L[TLS Listener Thread]
    end
    
    subgraph "Per-Client Threads"
        CH1[client_handler_thread 1]
        CH2[client_handler_thread 2]
        CHN[client_handler_thread N]
    end
    
    subgraph "Shared Resources"
        MUTEX[clients_mutex]
        SLOTS[client_slots[10]]
        DEV_CTX[device_context]
    end
    
    MAIN --> INIT
    INIT --> TLS_L
    
    TLS_L -->|accept| CH1
    TLS_L -->|accept| CH2
    TLS_L -->|accept| CHN
    
    CH1 -->|lock| MUTEX
    CH2 -->|lock| MUTEX
    CHN -->|lock| MUTEX
    
    MUTEX --> SLOTS
    
    CH1 -->|use| DEV_CTX
    CH2 -->|use| DEV_CTX
    CHN -->|use| DEV_CTX
    
    style MUTEX fill:#ff9
    style DEV_CTX fill:#9f9
```

## Memory Management

```mermaid
graph LR
    subgraph "Server Memory Layout"
        subgraph "Shared"
            CTX[Device Context]
            SSL[SSL Context]
        end
        
        subgraph "Client 1"
            PD1[Protection Domain]
            QP1[Queue Pair]
            CQ1[Completion Queues]
            MR1[Memory Region]
            BUF1[Send/Recv Buffers]
        end
        
        subgraph "Client 2"
            PD2[Protection Domain]
            QP2[Queue Pair]
            CQ2[Completion Queues]
            MR2[Memory Region]
            BUF2[Send/Recv Buffers]
        end
    end
    
    CTX --> PD1
    CTX --> PD2
    
    PD1 --> QP1
    PD1 --> MR1
    
    PD2 --> QP2
    PD2 --> MR2
    
    style CTX fill:#9f9
    style SSL fill:#9f9
```

## Security Architecture

```mermaid
graph TB
    subgraph "Attack Prevention"
        A1[Replay Attack]
        A2[MITM Attack]
        A3[PSN Prediction]
    end
    
    subgraph "Security Measures"
        S1[Unique PSN per Connection]
        S2[TLS Encryption]
        S3[Cryptographic Random]
    end
    
    subgraph "Implementation"
        I1[OpenSSL RAND_bytes]
        I2[TLS 1.2+]
        I3[24-bit PSN Space]
    end
    
    A1 -->|prevented by| S1
    A2 -->|prevented by| S2
    A3 -->|prevented by| S3
    
    S1 -->|via| I3
    S2 -->|via| I2
    S3 -->|via| I1
    
    style A1 fill:#f99
    style A2 fill:#f99
    style A3 fill:#f99
    style S1 fill:#9f9
    style S2 fill:#9f9
    style S3 fill:#9f9
```

## Performance Characteristics

| Metric | Value | Notes |
|--------|-------|-------|
| Max Concurrent Clients | 10 | Configurable via MAX_CLIENTS |
| PSN Generation Time | < 1ms | OpenSSL RAND_bytes |
| TLS Handshake | ~50ms | One-time per client |
| QP Setup Time | ~10ms | Including state transitions |
| Message Latency | < 1ms | RDMA zero-copy |
| Resource Sharing | 90% reduction | Single device context |

## Scalability Considerations

```mermaid
graph LR
    subgraph "Current (10 clients)"
        C10[Fixed Array<br/>10 slots]
        T10[10 Threads<br/>Static]
    end
    
    subgraph "Future (Dynamic)"
        CD[Dynamic Array<br/>Resizable]
        TP[Thread Pool<br/>Reusable]
        CQ[Connection Queue<br/>Backpressure]
    end
    
    C10 -->|upgrade| CD
    T10 -->|upgrade| TP
    CD --> CQ
    TP --> CQ
```

## Next: [Low-Level Design](LOW_LEVEL_DESIGN.md)