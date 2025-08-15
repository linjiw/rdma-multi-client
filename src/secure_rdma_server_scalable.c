/**
 * Scalable Secure RDMA Server
 * Optimized for handling 1000+ concurrent clients
 * Uses epoll for I/O multiplexing instead of thread-per-client
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <pthread.h>
#include <signal.h>
#include "rdma_compat.h"
#include "tls_utils.h"

// Configurable via environment variable or compile-time
#ifndef MAX_CLIENTS
#define MAX_CLIENTS_DEFAULT 1000
#else
#define MAX_CLIENTS_DEFAULT MAX_CLIENTS
#endif

#define RDMA_PORT 4791
#define BUFFER_SIZE 4096
#define MAX_EVENTS 64
#define WORKER_THREADS 4  // Thread pool size

// Client state
enum client_state {
    STATE_INIT,
    STATE_TLS_HANDSHAKE,
    STATE_PSN_EXCHANGE,
    STATE_RDMA_SETUP,
    STATE_CONNECTED,
    STATE_CLOSING
};

// Lightweight client connection structure
struct client_connection {
    int client_id;
    enum client_state state;
    int active;
    
    // TLS connection
    struct tls_connection *tls_conn;
    uint32_t local_psn;
    uint32_t remote_psn;
    
    // RDMA resources (minimal per-client)
    struct ibv_qp *qp;
    struct ibv_cq *cq;  // Shared CQ for multiple clients
    struct ibv_mr *mr;  // Memory region from pool
    
    // Buffers from pool
    void *send_buffer;
    void *recv_buffer;
    int buffer_id;
    
    // Stats
    uint64_t messages_received;
    uint64_t bytes_received;
    struct timeval connect_time;
};

// Memory pool for efficient allocation
struct memory_pool {
    void *base;
    size_t chunk_size;
    size_t num_chunks;
    int *free_list;
    int free_count;
    pthread_mutex_t lock;
};

// Thread pool work item
struct work_item {
    enum {
        WORK_ACCEPT,
        WORK_PROCESS,
        WORK_CLOSE
    } type;
    int client_id;
    void *data;
};

// Scalable server context
struct server_context {
    // Configuration
    int max_clients;
    int port;
    
    // Epoll
    int epoll_fd;
    struct epoll_event *events;
    
    // TLS
    SSL_CTX *ssl_ctx;
    int tls_listen_sock;
    
    // RDMA (shared resources)
    struct ibv_device **dev_list;
    struct ibv_context *device_ctx;
    struct ibv_pd *pd;  // Single PD for all clients
    struct ibv_comp_channel *comp_channel;
    struct ibv_cq **shared_cqs;  // Pool of CQs
    int num_cqs;
    
    // Client management
    struct client_connection **clients;
    int *free_slots;
    int free_slot_count;
    pthread_mutex_t clients_mutex;
    
    // Memory pools
    struct memory_pool *buffer_pool;
    struct memory_pool *qp_pool;
    
    // Thread pool
    pthread_t *worker_threads;
    int num_workers;
    
    // Statistics
    uint64_t total_connections;
    uint64_t active_connections;
    uint64_t total_messages;
    uint64_t total_bytes;
    
    // Server state
    volatile int running;
};

static struct server_context *g_server = NULL;

// Initialize memory pool
static struct memory_pool* create_memory_pool(size_t chunk_size, size_t num_chunks) {
    struct memory_pool *pool = calloc(1, sizeof(struct memory_pool));
    if (!pool) return NULL;
    
    pool->chunk_size = chunk_size;
    pool->num_chunks = num_chunks;
    pool->base = calloc(num_chunks, chunk_size);
    pool->free_list = malloc(num_chunks * sizeof(int));
    
    if (!pool->base || !pool->free_list) {
        free(pool->base);
        free(pool->free_list);
        free(pool);
        return NULL;
    }
    
    // Initialize free list
    for (int i = 0; i < num_chunks; i++) {
        pool->free_list[i] = i;
    }
    pool->free_count = num_chunks;
    pthread_mutex_init(&pool->lock, NULL);
    
    return pool;
}

// Allocate from memory pool
static void* pool_alloc(struct memory_pool *pool, int *id) {
    pthread_mutex_lock(&pool->lock);
    
    if (pool->free_count == 0) {
        pthread_mutex_unlock(&pool->lock);
        return NULL;
    }
    
    int chunk_id = pool->free_list[--pool->free_count];
    *id = chunk_id;
    
    pthread_mutex_unlock(&pool->lock);
    
    return (char*)pool->base + (chunk_id * pool->chunk_size);
}

// Free to memory pool
static void pool_free(struct memory_pool *pool, int id) {
    pthread_mutex_lock(&pool->lock);
    pool->free_list[pool->free_count++] = id;
    pthread_mutex_unlock(&pool->lock);
}

// Get free client slot
static int get_free_client_slot(struct server_context *server) {
    pthread_mutex_lock(&server->clients_mutex);
    
    if (server->free_slot_count == 0) {
        pthread_mutex_unlock(&server->clients_mutex);
        return -1;
    }
    
    int slot = server->free_slots[--server->free_slot_count];
    server->active_connections++;
    
    pthread_mutex_unlock(&server->clients_mutex);
    return slot;
}

// Release client slot
static void release_client_slot(struct server_context *server, int slot) {
    pthread_mutex_lock(&server->clients_mutex);
    
    server->free_slots[server->free_slot_count++] = slot;
    server->active_connections--;
    
    // Clear client structure
    if (server->clients[slot]) {
        memset(server->clients[slot], 0, sizeof(struct client_connection));
    }
    
    pthread_mutex_unlock(&server->clients_mutex);
}

// Initialize RDMA resources (shared)
static int init_rdma_shared(struct server_context *server) {
    // Get device list
    int num_devices;
    server->dev_list = ibv_get_device_list(&num_devices);
    if (!server->dev_list || num_devices == 0) {
        fprintf(stderr, "No RDMA devices found\n");
        return -1;
    }
    
    // Open first device
    server->device_ctx = ibv_open_device(server->dev_list[0]);
    if (!server->device_ctx) {
        fprintf(stderr, "Failed to open RDMA device\n");
        return -1;
    }
    
    // Create single PD for all clients
    server->pd = ibv_alloc_pd(server->device_ctx);
    if (!server->pd) {
        fprintf(stderr, "Failed to allocate PD\n");
        return -1;
    }
    
    // Create completion channel
    server->comp_channel = ibv_create_comp_channel(server->device_ctx);
    if (!server->comp_channel) {
        fprintf(stderr, "Failed to create completion channel\n");
        return -1;
    }
    
    // Create pool of shared CQs
    server->num_cqs = WORKER_THREADS;
    server->shared_cqs = calloc(server->num_cqs, sizeof(struct ibv_cq*));
    
    for (int i = 0; i < server->num_cqs; i++) {
        server->shared_cqs[i] = ibv_create_cq(server->device_ctx, 
                                               server->max_clients / server->num_cqs + 1,
                                               NULL, server->comp_channel, 0);
        if (!server->shared_cqs[i]) {
            fprintf(stderr, "Failed to create CQ %d\n", i);
            return -1;
        }
    }
    
    printf("RDMA shared resources initialized:\n");
    printf("  Device: %s\n", ibv_get_device_name(server->dev_list[0]));
    printf("  PD: Single shared PD\n");
    printf("  CQs: %d shared CQs\n", server->num_cqs);
    
    return 0;
}

// Create QP for client (optimized)
static struct ibv_qp* create_client_qp(struct server_context *server, int client_id) {
    struct ibv_qp_init_attr qp_attr = {
        .send_cq = server->shared_cqs[client_id % server->num_cqs],
        .recv_cq = server->shared_cqs[client_id % server->num_cqs],
        .qp_type = IBV_QPT_RC,
        .cap = {
            .max_send_wr = 10,  // Reduced for scalability
            .max_recv_wr = 10,
            .max_send_sge = 1,
            .max_recv_sge = 1,
            .max_inline_data = 64  // Small inline data
        }
    };
    
    return ibv_create_qp(server->pd, &qp_attr);
}

// Handle new client connection (lightweight)
static int handle_new_client(struct server_context *server, int tls_sock) {
    int client_slot = get_free_client_slot(server);
    if (client_slot < 0) {
        fprintf(stderr, "No free client slots (max: %d)\n", server->max_clients);
        close(tls_sock);
        return -1;
    }
    
    struct client_connection *client = server->clients[client_slot];
    if (!client) {
        client = calloc(1, sizeof(struct client_connection));
        server->clients[client_slot] = client;
    }
    
    client->client_id = client_slot;
    client->state = STATE_TLS_HANDSHAKE;
    client->active = 1;
    gettimeofday(&client->connect_time, NULL);
    
    // Get buffers from pool
    client->send_buffer = pool_alloc(server->buffer_pool, &client->buffer_id);
    client->recv_buffer = (char*)client->send_buffer + BUFFER_SIZE;
    
    if (!client->send_buffer) {
        fprintf(stderr, "Failed to allocate buffers for client %d\n", client_slot);
        release_client_slot(server, client_slot);
        return -1;
    }
    
    // Create QP
    client->qp = create_client_qp(server, client_slot);
    if (!client->qp) {
        fprintf(stderr, "Failed to create QP for client %d\n", client_slot);
        pool_free(server->buffer_pool, client->buffer_id);
        release_client_slot(server, client_slot);
        return -1;
    }
    
    // Add to epoll for async I/O
    struct epoll_event ev;
    ev.events = EPOLLIN | EPOLLET;
    ev.data.u32 = client_slot;
    
    if (epoll_ctl(server->epoll_fd, EPOLL_CTL_ADD, tls_sock, &ev) < 0) {
        perror("epoll_ctl");
        ibv_destroy_qp(client->qp);
        pool_free(server->buffer_pool, client->buffer_id);
        release_client_slot(server, client_slot);
        return -1;
    }
    
    server->total_connections++;
    
    if (server->active_connections % 100 == 0) {
        printf("Active connections: %lu/%d\n", 
               server->active_connections, server->max_clients);
    }
    
    return 0;
}

// Initialize server
static int init_server(struct server_context *server) {
    // Set max clients from environment or use default
    const char *max_clients_env = getenv("MAX_CLIENTS");
    if (max_clients_env) {
        server->max_clients = atoi(max_clients_env);
    } else {
        server->max_clients = MAX_CLIENTS_DEFAULT;
    }
    
    printf("Initializing scalable server for %d max clients\n", server->max_clients);
    
    // Initialize client array and free slots
    server->clients = calloc(server->max_clients, sizeof(struct client_connection*));
    server->free_slots = malloc(server->max_clients * sizeof(int));
    
    for (int i = 0; i < server->max_clients; i++) {
        server->free_slots[i] = server->max_clients - 1 - i;
    }
    server->free_slot_count = server->max_clients;
    
    // Create memory pools
    int buffer_pool_size = server->max_clients * 2;  // 2x for headroom
    server->buffer_pool = create_memory_pool(BUFFER_SIZE * 2, buffer_pool_size);
    if (!server->buffer_pool) {
        fprintf(stderr, "Failed to create buffer pool\n");
        return -1;
    }
    
    // Initialize epoll
    server->epoll_fd = epoll_create1(0);
    if (server->epoll_fd < 0) {
        perror("epoll_create1");
        return -1;
    }
    
    server->events = calloc(MAX_EVENTS, sizeof(struct epoll_event));
    
    // Initialize RDMA
    if (init_rdma_shared(server) < 0) {
        return -1;
    }
    
    // Initialize TLS
    if (init_tls_server(&server->ssl_ctx) < 0) {
        return -1;
    }
    
    // Create TLS listening socket
    server->tls_listen_sock = create_tls_server_socket(TLS_PORT);
    if (server->tls_listen_sock < 0) {
        return -1;
    }
    
    printf("Scalable server initialized successfully\n");
    printf("  Max clients: %d\n", server->max_clients);
    printf("  Buffer pool: %d chunks\n", buffer_pool_size);
    printf("  Worker threads: %d\n", WORKER_THREADS);
    
    return 0;
}

// Main server loop (epoll-based)
static void server_loop(struct server_context *server) {
    printf("Server running on ports: TLS=%d, RDMA=%d\n", TLS_PORT, RDMA_PORT);
    printf("Waiting for connections...\n");
    
    while (server->running) {
        int nfds = epoll_wait(server->epoll_fd, server->events, MAX_EVENTS, 1000);
        
        if (nfds < 0) {
            if (errno == EINTR) continue;
            perror("epoll_wait");
            break;
        }
        
        for (int i = 0; i < nfds; i++) {
            if (server->events[i].data.fd == server->tls_listen_sock) {
                // New connection
                struct sockaddr_in client_addr;
                socklen_t addr_len = sizeof(client_addr);
                int client_sock = accept(server->tls_listen_sock, 
                                        (struct sockaddr*)&client_addr, 
                                        &addr_len);
                
                if (client_sock >= 0) {
                    handle_new_client(server, client_sock);
                }
            } else {
                // Handle client I/O
                int client_id = server->events[i].data.u32;
                // Process client events...
            }
        }
        
        // Periodic stats
        static time_t last_stats = 0;
        time_t now = time(NULL);
        if (now - last_stats >= 10) {
            printf("Stats: Connections=%lu active=%lu, Messages=%lu, Data=%.2f MB\n",
                   server->total_connections, server->active_connections,
                   server->total_messages, 
                   server->total_bytes / (1024.0 * 1024.0));
            last_stats = now;
        }
    }
}

// Signal handler
static void signal_handler(int sig) {
    printf("\nReceived signal %d, shutting down...\n", sig);
    if (g_server) {
        g_server->running = 0;
    }
}

int main(int argc, char *argv[]) {
    // Create server context
    g_server = calloc(1, sizeof(struct server_context));
    if (!g_server) {
        fprintf(stderr, "Failed to allocate server context\n");
        return 1;
    }
    
    g_server->running = 1;
    g_server->port = RDMA_PORT;
    pthread_mutex_init(&g_server->clients_mutex, NULL);
    
    // Set up signal handlers
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);
    
    // Initialize server
    if (init_server(g_server) < 0) {
        fprintf(stderr, "Failed to initialize server\n");
        return 1;
    }
    
    // Run server
    server_loop(g_server);
    
    // Cleanup
    printf("Server shutdown complete\n");
    printf("Total connections handled: %lu\n", g_server->total_connections);
    
    return 0;
}