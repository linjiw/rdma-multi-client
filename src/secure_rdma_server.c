/**
 * Secure RDMA Server with Multi-Client Support
 * Features:
 * - TLS-based PSN exchange
 * - Multiple concurrent client connections
 * - Secure RDMA operations
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <signal.h>
#include <errno.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include "rdma_compat.h"
#include "tls_utils.h"

#define MAX_CLIENTS 10
#define RDMA_PORT 4791
#define BUFFER_SIZE 4096
#define TIMEOUT_MS 5000

// Client connection structure
struct client_connection {
    // Client identification
    int client_id;
    pthread_t thread_id;
    volatile int active;
    
    // TLS connection
    struct tls_connection *tls_conn;
    uint32_t local_psn;
    uint32_t remote_psn;
    
    // RDMA resources
    struct rdma_cm_id *cm_id;
    struct ibv_qp *qp;
    struct ibv_pd *pd;
    struct ibv_cq *send_cq;
    struct ibv_cq *recv_cq;
    struct ibv_mr *send_mr;
    struct ibv_mr *recv_mr;
    char *send_buffer;
    char *recv_buffer;
    
    // Remote connection info
    struct rdma_conn_params remote_params;
    
    // Server context reference
    struct server_context *server;
};

// Server context
struct server_context {
    // TLS server
    SSL_CTX *ssl_ctx;
    int tls_listen_sock;
    pthread_t tls_thread;
    
    // RDMA server
    struct rdma_event_channel *ec;
    struct rdma_cm_id *listener;
    pthread_t rdma_thread;
    
    // Client management
    struct client_connection *clients[MAX_CLIENTS];
    pthread_mutex_t clients_mutex;
    int num_clients;
    
    // Server state
    volatile int running;
};

static struct server_context *g_server = NULL;

// Signal handler for graceful shutdown
static void signal_handler(int sig) {
    printf("\nReceived signal %d, shutting down...\n", sig);
    if (g_server) {
        g_server->running = 0;
    }
}

// Initialize RDMA resources for a client
static int init_rdma_resources(struct client_connection *client) {
    // Allocate buffers
    client->send_buffer = calloc(1, BUFFER_SIZE);
    client->recv_buffer = calloc(1, BUFFER_SIZE);
    
    if (!client->send_buffer || !client->recv_buffer) {
        perror("Failed to allocate buffers");
        return -1;
    }
    
    // PD and QP are already created directly, not through CM ID
    // So we don't need to get them from cm_id
    
    // Register memory regions
    client->send_mr = ibv_reg_mr(client->pd, client->send_buffer, BUFFER_SIZE,
                                 IBV_ACCESS_LOCAL_WRITE | IBV_ACCESS_REMOTE_READ);
    client->recv_mr = ibv_reg_mr(client->pd, client->recv_buffer, BUFFER_SIZE,
                                 IBV_ACCESS_LOCAL_WRITE | IBV_ACCESS_REMOTE_WRITE);
    
    if (!client->send_mr || !client->recv_mr) {
        perror("Failed to register memory");
        return -1;
    }
    
    return 0;
}

// Setup QP with secure PSN
static int setup_qp_with_psn(struct client_connection *client) {
    struct ibv_qp_attr attr;
    int flags;
    
    // Get port attributes
    struct ibv_port_attr port_attr;
    if (ibv_query_port(client->pd->context, 1, &port_attr)) {  // Use port 1
        perror("ibv_query_port");
        return -1;
    }
    
    // Prepare local connection parameters
    struct rdma_conn_params local_params;
    local_params.qp_num = client->qp->qp_num;
    local_params.lid = port_attr.lid;
    local_params.psn = client->local_psn;
    local_params.rkey = client->recv_mr->rkey;
    local_params.remote_addr = (uint64_t)client->recv_buffer;
    
    // Query GID
    if (ibv_query_gid(client->pd->context, 1,  // Use port 1 
                     0, (union ibv_gid*)local_params.gid)) {
        perror("ibv_query_gid");
        return -1;
    }
    
    // Exchange RDMA parameters over TLS
    printf("Server: Sending RDMA params to client %d\n", client->client_id);
    if (send_rdma_params(client->tls_conn, &local_params) < 0) {
        fprintf(stderr, "Failed to send RDMA parameters\n");
        return -1;
    }
    
    printf("Server: Waiting to receive RDMA params from client %d\n", client->client_id);
    if (receive_rdma_params(client->tls_conn, &client->remote_params) < 0) {
        fprintf(stderr, "Failed to receive RDMA parameters\n");
        return -1;
    }
    printf("Server: RDMA params exchange complete for client %d\n", client->client_id);
    
    printf("Client %d: QP %d <-> QP %d, PSN 0x%06x <-> 0x%06x\n",
           client->client_id, local_params.qp_num, client->remote_params.qp_num,
           client->local_psn, client->remote_psn);
    
    // When using RDMA CM, the QP state transitions are handled automatically
    // by rdma_accept() and rdma_connect(). We don't need manual transitions.
    // The QP should already be in RTS (Ready To Send) state after connection.
    
    // However, we still need to set the PSN values for security
    // Check current QP state first
    struct ibv_qp_attr qp_attr;
    struct ibv_qp_init_attr init_attr;
    if (ibv_query_qp(client->qp, &qp_attr, IBV_QP_STATE, &init_attr) == 0) {
        printf("Client %d: QP state after accept: %d\n", client->client_id, qp_attr.qp_state);
    }
    
    // Manual QP state transitions with custom PSN
    // We don't use rdma_accept() to have control over PSN values
    
    // Step 1: Transition QP to INIT state
    memset(&attr, 0, sizeof(attr));
    attr.qp_state = IBV_QPS_INIT;
    attr.port_num = 1;  // Use port 1 (default for first port)
    attr.pkey_index = 0;
    attr.qp_access_flags = IBV_ACCESS_LOCAL_WRITE | 
                          IBV_ACCESS_REMOTE_READ |
                          IBV_ACCESS_REMOTE_WRITE;
    
    flags = IBV_QP_STATE | IBV_QP_PKEY_INDEX | IBV_QP_PORT | IBV_QP_ACCESS_FLAGS;
    
    if (ibv_modify_qp(client->qp, &attr, flags)) {
        perror("Server: Failed to modify QP to INIT");
        return -1;
    }
    printf("Server: Client %d QP transitioned to INIT\n", client->client_id);
    
    // Step 2: Transition QP to RTR (Ready to Receive) with remote PSN
    memset(&attr, 0, sizeof(attr));
    attr.qp_state = IBV_QPS_RTR;
    attr.path_mtu = IBV_MTU_1024;
    attr.dest_qp_num = client->remote_params.qp_num;
    attr.rq_psn = client->remote_psn;  // Use secure PSN from client
    attr.max_dest_rd_atomic = 1;
    attr.min_rnr_timer = 12;
    
    // Setup address handle
    attr.ah_attr.is_global = 0;
    attr.ah_attr.dlid = client->remote_params.lid;
    attr.ah_attr.sl = 0;
    attr.ah_attr.src_path_bits = 0;
    attr.ah_attr.port_num = 1;  // Use port 1
    
    // If using RoCE (Ethernet), setup GID
    if (port_attr.link_layer == IBV_LINK_LAYER_ETHERNET) {
        attr.ah_attr.is_global = 1;
        attr.ah_attr.grh.hop_limit = 1;
        memcpy(&attr.ah_attr.grh.dgid, client->remote_params.gid, 16);
        attr.ah_attr.grh.sgid_index = 0;
    }
    
    flags = IBV_QP_STATE | IBV_QP_AV | IBV_QP_PATH_MTU | 
            IBV_QP_DEST_QPN | IBV_QP_RQ_PSN |
            IBV_QP_MAX_DEST_RD_ATOMIC | IBV_QP_MIN_RNR_TIMER;
    
    if (ibv_modify_qp(client->qp, &attr, flags)) {
        perror("Server: Failed to modify QP to RTR");
        return -1;
    }
    printf("Server: Client %d QP transitioned to RTR with remote PSN 0x%06x\n", 
           client->client_id, client->remote_psn);
    
    // Step 3: Transition QP to RTS (Ready to Send) with local PSN
    memset(&attr, 0, sizeof(attr));
    attr.qp_state = IBV_QPS_RTS;
    attr.timeout = 14;
    attr.retry_cnt = 7;
    attr.rnr_retry = 7;
    attr.sq_psn = client->local_psn;  // Use secure PSN for sending
    attr.max_rd_atomic = 1;
    
    flags = IBV_QP_STATE | IBV_QP_TIMEOUT | IBV_QP_RETRY_CNT |
            IBV_QP_RNR_RETRY | IBV_QP_SQ_PSN | IBV_QP_MAX_QP_RD_ATOMIC;
    
    if (ibv_modify_qp(client->qp, &attr, flags)) {
        perror("Server: Failed to modify QP to RTS");
        return -1;
    }
    
    printf("Server: Client %d QP transitioned to RTS with local PSN 0x%06x\n", 
           client->client_id, client->local_psn);
    return 0;
}

// Post receive buffer
static int post_receive(struct client_connection *client) {
    struct ibv_sge sge;
    struct ibv_recv_wr wr, *bad_wr;
    
    memset(&sge, 0, sizeof(sge));
    sge.addr = (uintptr_t)client->recv_buffer;
    sge.length = BUFFER_SIZE;
    sge.lkey = client->recv_mr->lkey;
    
    memset(&wr, 0, sizeof(wr));
    wr.wr_id = (uintptr_t)client;
    wr.sg_list = &sge;
    wr.num_sge = 1;
    
    if (ibv_post_recv(client->qp, &wr, &bad_wr)) {
        perror("ibv_post_recv");
        return -1;
    }
    
    return 0;
}

// Send message to client
static int send_message(struct client_connection *client, const char *message) {
    struct ibv_sge sge;
    struct ibv_send_wr wr, *bad_wr;
    struct ibv_wc wc;
    
    strcpy(client->send_buffer, message);
    
    memset(&sge, 0, sizeof(sge));
    sge.addr = (uintptr_t)client->send_buffer;
    sge.length = strlen(message) + 1;
    sge.lkey = client->send_mr->lkey;
    
    memset(&wr, 0, sizeof(wr));
    wr.wr_id = (uintptr_t)client;
    wr.opcode = IBV_WR_SEND;
    wr.sg_list = &sge;
    wr.num_sge = 1;
    wr.send_flags = IBV_SEND_SIGNALED;
    
    if (ibv_post_send(client->qp, &wr, &bad_wr)) {
        perror("ibv_post_send");
        return -1;
    }
    
    // Wait for completion
    while (ibv_poll_cq(client->cm_id->send_cq, 1, &wc) == 0);
    
    if (wc.status != IBV_WC_SUCCESS) {
        fprintf(stderr, "Send failed with status: %s\n", 
                ibv_wc_status_str(wc.status));
        return -1;
    }
    
    printf("Client %d: Sent: %s\n", client->client_id, message);
    return 0;
}

// Handle client RDMA operations
static void handle_client_rdma(struct client_connection *client) {
    struct ibv_wc wc;
    char response[256];
    
    printf("Client %d: Starting RDMA operations\n", client->client_id);
    
    // Post initial receive
    if (post_receive(client) < 0) {
        fprintf(stderr, "Client %d: Failed to post receive\n", client->client_id);
        return;
    }
    
    // Send welcome message
    snprintf(response, sizeof(response), 
             "Welcome Client %d! Server PSN: 0x%06x, Your PSN: 0x%06x",
             client->client_id, client->local_psn, client->remote_psn);
    
    if (send_message(client, response) < 0) {
        fprintf(stderr, "Client %d: Failed to send welcome\n", client->client_id);
        return;
    }
    
    // Main operation loop
    while (client->active && client->server->running) {
        // Poll for receive completions
        if (ibv_poll_cq(client->cm_id->recv_cq, 1, &wc) > 0) {
            if (wc.status == IBV_WC_SUCCESS) {
                printf("Client %d: Received: %s\n", client->client_id, client->recv_buffer);
                
                // Echo back with client ID
                snprintf(response, sizeof(response), 
                        "Server echo [Client %d]: %s", 
                        client->client_id, client->recv_buffer);
                
                if (send_message(client, response) < 0) {
                    break;
                }
                
                // Post another receive
                if (post_receive(client) < 0) {
                    break;
                }
            } else {
                fprintf(stderr, "Client %d: Receive failed: %s\n", 
                       client->client_id, ibv_wc_status_str(wc.status));
                break;
            }
        }
        
        usleep(1000); // 1ms polling interval
    }
    
    printf("Client %d: RDMA operations completed\n", client->client_id);
}

// Client handler thread
static void* client_handler_thread(void *arg) {
    struct client_connection *client = (struct client_connection *)arg;
    
    printf("Client %d: Handler thread started\n", client->client_id);
    
    // Exchange PSN over TLS
    if (exchange_psn_server(client->tls_conn, &client->local_psn, &client->remote_psn) < 0) {
        fprintf(stderr, "Client %d: PSN exchange failed\n", client->client_id);
        goto cleanup;
    }
    
    // Create RDMA resources immediately (no waiting for RDMA CM events)
    // We'll create everything we need right here after PSN exchange
    
    printf("Client %d: Creating RDMA resources without RDMA CM events\n", client->client_id);
    
    // Open RDMA device directly instead of using RDMA CM
    struct ibv_device **dev_list;
    int num_devices;
    
    dev_list = ibv_get_device_list(&num_devices);
    if (!dev_list || num_devices == 0) {
        fprintf(stderr, "No RDMA devices found\n");
        goto cleanup;
    }
    
    // Use the first available device
    struct ibv_context *ctx = ibv_open_device(dev_list[0]);
    ibv_free_device_list(dev_list);
    
    if (!ctx) {
        fprintf(stderr, "Failed to open RDMA device\n");
        goto cleanup;
    }
    
    printf("Client %d: Opened RDMA device %s\n", client->client_id, 
           ibv_get_device_name(ctx->device));
    
    // Create protection domain
    client->pd = ibv_alloc_pd(ctx);
    if (!client->pd) {
        perror("ibv_alloc_pd");
        ibv_close_device(ctx);
        goto cleanup;
    }
    
    // Create QP
    struct ibv_qp_init_attr qp_attr;
    memset(&qp_attr, 0, sizeof(qp_attr));
    qp_attr.send_cq = ibv_create_cq(ctx, 10, NULL, NULL, 0);
    qp_attr.recv_cq = ibv_create_cq(ctx, 10, NULL, NULL, 0);
    qp_attr.qp_type = IBV_QPT_RC;
    qp_attr.cap.max_send_wr = 10;
    qp_attr.cap.max_recv_wr = 10;
    qp_attr.cap.max_send_sge = 1;
    qp_attr.cap.max_recv_sge = 1;
    
    if (!qp_attr.send_cq || !qp_attr.recv_cq) {
        fprintf(stderr, "Failed to create CQ\n");
        if (qp_attr.send_cq) ibv_destroy_cq(qp_attr.send_cq);
        if (qp_attr.recv_cq) ibv_destroy_cq(qp_attr.recv_cq);
        ibv_dealloc_pd(client->pd);
        ibv_close_device(ctx);
        goto cleanup;
    }
    
    // Store CQs
    client->send_cq = qp_attr.send_cq;
    client->recv_cq = qp_attr.recv_cq;
    
    // Create QP directly using ibv_create_qp
    client->qp = ibv_create_qp(client->pd, &qp_attr);
    if (!client->qp) {
        perror("ibv_create_qp");
        ibv_destroy_cq(client->send_cq);
        ibv_destroy_cq(client->recv_cq);
        ibv_dealloc_pd(client->pd);
        ibv_close_device(ctx);
        goto cleanup;
    }
    
    printf("Client %d: QP created successfully (QP num: %d)\n", 
           client->client_id, client->qp->qp_num);
    
    // Store the context for later use
    // We need to add this to the client structure
    // For now, we'll work with what we have
    
    // Initialize RDMA resources (buffers and MRs)
    if (init_rdma_resources(client) < 0) {
        fprintf(stderr, "Client %d: Failed to init RDMA resources\n", client->client_id);
        goto cleanup;
    }
    
    // Setup QP with secure PSN
    printf("Server: Client %d - Starting setup_qp_with_psn\n", client->client_id);
    if (setup_qp_with_psn(client) < 0) {
        fprintf(stderr, "Client %d: Failed to setup QP\n", client->client_id);
        goto cleanup;
    }
    printf("Server: Client %d - setup_qp_with_psn completed successfully\n", client->client_id);
    
    // Handle RDMA operations
    handle_client_rdma(client);
    
cleanup:
    printf("Client %d: Cleaning up\n", client->client_id);
    
    // Clean up RDMA resources
    if (client->send_mr) ibv_dereg_mr(client->send_mr);
    if (client->recv_mr) ibv_dereg_mr(client->recv_mr);
    if (client->cm_id) {
        rdma_disconnect(client->cm_id);
        rdma_destroy_id(client->cm_id);
    }
    free(client->send_buffer);
    free(client->recv_buffer);
    
    // Close TLS connection
    close_tls_connection(client->tls_conn);
    
    // Remove from server's client list
    pthread_mutex_lock(&client->server->clients_mutex);
    for (int i = 0; i < MAX_CLIENTS; i++) {
        if (client->server->clients[i] == client) {
            client->server->clients[i] = NULL;
            client->server->num_clients--;
            break;
        }
    }
    pthread_mutex_unlock(&client->server->clients_mutex);
    
    free(client);
    
    return NULL;
}

// TLS listener thread
static void* tls_listener_thread(void *arg) {
    struct server_context *server = (struct server_context *)arg;
    
    printf("TLS listener thread started\n");
    
    while (server->running) {
        struct tls_connection *tls_conn;
        struct client_connection *client;
        
        // Accept TLS connection
        tls_conn = accept_tls_connection(server->tls_listen_sock, server->ssl_ctx);
        if (!tls_conn) {
            if (server->running) {
                fprintf(stderr, "Failed to accept TLS connection\n");
            }
            continue;
        }
        
        // Check if we can accept more clients
        pthread_mutex_lock(&server->clients_mutex);
        if (server->num_clients >= MAX_CLIENTS) {
            pthread_mutex_unlock(&server->clients_mutex);
            fprintf(stderr, "Maximum clients reached, rejecting connection\n");
            close_tls_connection(tls_conn);
            continue;
        }
        
        // Create client connection structure
        client = calloc(1, sizeof(*client));
        if (!client) {
            pthread_mutex_unlock(&server->clients_mutex);
            close_tls_connection(tls_conn);
            continue;
        }
        
        // Initialize client
        client->tls_conn = tls_conn;
        client->server = server;
        client->active = 1;
        
        // Find free slot and assign client ID
        for (int i = 0; i < MAX_CLIENTS; i++) {
            if (server->clients[i] == NULL) {
                server->clients[i] = client;
                client->client_id = i + 1;
                server->num_clients++;
                break;
            }
        }
        pthread_mutex_unlock(&server->clients_mutex);
        
        printf("Client %d: TLS connection accepted\n", client->client_id);
        
        // Create handler thread for this client
        if (pthread_create(&client->thread_id, NULL, client_handler_thread, client) != 0) {
            fprintf(stderr, "Failed to create client handler thread\n");
            close_tls_connection(tls_conn);
            free(client);
        }
        
        pthread_detach(client->thread_id);
    }
    
    printf("TLS listener thread exiting\n");
    return NULL;
}

// RDMA connection handler
static int handle_rdma_connection(struct rdma_cm_id *id) {
    struct client_connection *client = NULL;
    struct ibv_qp_init_attr qp_attr;
    
    // Find the client by comparing addresses
    struct sockaddr_in *client_addr = (struct sockaddr_in *)&id->route.addr.dst_addr;
    
    pthread_mutex_lock(&g_server->clients_mutex);
    // For simplicity, assign to the most recent client without CM ID
    for (int i = 0; i < MAX_CLIENTS; i++) {
        if (g_server->clients[i] && !g_server->clients[i]->cm_id) {
            client = g_server->clients[i];
            client->cm_id = id;
            id->context = client;
            break;
        }
    }
    pthread_mutex_unlock(&g_server->clients_mutex);
    
    if (!client) {
        fprintf(stderr, "No matching client found for RDMA connection\n");
        return -1;
    }
    
    printf("Client %d: RDMA connection request received\n", client->client_id);
    
    // Create QP for this connection (matching client's QP creation)
    memset(&qp_attr, 0, sizeof(qp_attr));
    qp_attr.send_cq = ibv_create_cq(id->verbs, 10, NULL, NULL, 0);
    qp_attr.recv_cq = ibv_create_cq(id->verbs, 10, NULL, NULL, 0);
    qp_attr.qp_type = IBV_QPT_RC;
    qp_attr.cap.max_send_wr = 10;
    qp_attr.cap.max_recv_wr = 10;
    qp_attr.cap.max_send_sge = 1;
    qp_attr.cap.max_recv_sge = 1;
    
    if (!qp_attr.send_cq || !qp_attr.recv_cq) {
        fprintf(stderr, "Failed to create CQ\n");
        return -1;
    }
    
    if (rdma_create_qp(id, NULL, &qp_attr)) {
        perror("rdma_create_qp");
        ibv_destroy_cq(qp_attr.send_cq);
        ibv_destroy_cq(qp_attr.recv_cq);
        return -1;
    }
    
    // Store CQs in client structure for cleanup
    client->send_cq = qp_attr.send_cq;
    client->recv_cq = qp_attr.recv_cq;
    
    printf("Client %d: QP created successfully (QP num: %d)\n", 
           client->client_id, id->qp->qp_num);
    
    // We don't use rdma_accept() because it automatically transitions QP to RTS
    // and we need to set custom PSN values during the transition
    // The actual connection will be established via manual QP transitions in setup_qp_with_psn()
    
    printf("Client %d: RDMA QP created, waiting for parameter exchange\n", client->client_id);
    return 0;
}

// RDMA listener thread
static void* rdma_listener_thread(void *arg) {
    struct server_context *server = (struct server_context *)arg;
    struct rdma_cm_event *event;
    int ret;
    
    printf("RDMA listener thread started\n");
    
    while (server->running) {
        ret = rdma_get_cm_event(server->ec, &event);
        if (ret) {
            if (server->running) {
                perror("rdma_get_cm_event");
            }
            break;
        }
        
        switch (event->event) {
            case RDMA_CM_EVENT_CONNECT_REQUEST:
                handle_rdma_connection(event->id);
                break;
                
            case RDMA_CM_EVENT_ESTABLISHED:
                printf("RDMA connection established\n");
                break;
                
            case RDMA_CM_EVENT_DISCONNECTED:
                printf("RDMA client disconnected\n");
                if (event->id->context) {
                    struct client_connection *client = event->id->context;
                    client->active = 0;
                }
                rdma_destroy_id(event->id);
                break;
                
            default:
                printf("Unexpected RDMA event: %s\n", rdma_event_str(event->event));
                break;
        }
        
        rdma_ack_cm_event(event);
    }
    
    printf("RDMA listener thread exiting\n");
    return NULL;
}

// Initialize server
static struct server_context* init_server(void) {
    struct server_context *server;
    struct sockaddr_in addr;
    
    server = calloc(1, sizeof(*server));
    if (!server) {
        return NULL;
    }
    
    server->running = 1;
    pthread_mutex_init(&server->clients_mutex, NULL);
    
    // Initialize OpenSSL
    init_openssl();
    
    // Create TLS context
    server->ssl_ctx = create_server_context();
    if (!server->ssl_ctx) {
        free(server);
        return NULL;
    }
    
    // Configure TLS certificates
    if (configure_server_context(server->ssl_ctx, CERT_FILE, KEY_FILE) < 0) {
        // Generate self-signed certificate if not found
        printf("Generating self-signed certificate...\n");
        system("openssl req -x509 -newkey rsa:2048 -keyout server.key -out server.crt "
               "-days 365 -nodes -subj '/CN=localhost'");
        
        if (configure_server_context(server->ssl_ctx, CERT_FILE, KEY_FILE) < 0) {
            SSL_CTX_free(server->ssl_ctx);
            free(server);
            return NULL;
        }
    }
    
    // Create TLS listener
    server->tls_listen_sock = create_tls_listener(TLS_PORT);
    if (server->tls_listen_sock < 0) {
        SSL_CTX_free(server->ssl_ctx);
        free(server);
        return NULL;
    }
    
    // RDMA CM listener not needed - we create QPs directly after TLS connection
    // Each client will get its own RDMA resources created in the handler thread
    printf("RDMA resources will be created per-client after TLS connection\n");
    
    // Initialize these to NULL since we're not using them
    server->ec = NULL;
    server->listener = NULL;
    
    return server;
}

// Cleanup server
static void cleanup_server(struct server_context *server) {
    if (!server) return;
    
    server->running = 0;
    
    // Wait for threads to finish
    if (server->tls_thread) {
        pthread_join(server->tls_thread, NULL);
    }
    if (server->rdma_thread) {
        pthread_join(server->rdma_thread, NULL);
    }
    
    // Clean up remaining clients
    pthread_mutex_lock(&server->clients_mutex);
    for (int i = 0; i < MAX_CLIENTS; i++) {
        if (server->clients[i]) {
            server->clients[i]->active = 0;
        }
    }
    pthread_mutex_unlock(&server->clients_mutex);
    
    // Clean up RDMA
    if (server->listener) {
        rdma_destroy_id(server->listener);
    }
    if (server->ec) {
        rdma_destroy_event_channel(server->ec);
    }
    
    // Clean up TLS
    if (server->tls_listen_sock >= 0) {
        close(server->tls_listen_sock);
    }
    if (server->ssl_ctx) {
        SSL_CTX_free(server->ssl_ctx);
    }
    
    cleanup_openssl();
    pthread_mutex_destroy(&server->clients_mutex);
    free(server);
}

int main(int argc, char *argv[]) {
    (void)argc;
    (void)argv;
    
    // Setup signal handlers
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);
    
    // Initialize server
    g_server = init_server();
    if (!g_server) {
        fprintf(stderr, "Failed to initialize server\n");
        return 1;
    }
    
    // Create TLS listener thread
    if (pthread_create(&g_server->tls_thread, NULL, tls_listener_thread, g_server) != 0) {
        fprintf(stderr, "Failed to create TLS listener thread\n");
        cleanup_server(g_server);
        return 1;
    }
    
    // RDMA listener thread not needed - we create QPs directly after TLS connection
    // This allows us to control PSN values during QP state transitions
    /*
    if (pthread_create(&g_server->rdma_thread, NULL, rdma_listener_thread, g_server) != 0) {
        fprintf(stderr, "Failed to create RDMA listener thread\n");
        cleanup_server(g_server);
        return 1;
    }
    */
    
    printf("Secure RDMA Server started\n");
    printf("TLS Port: %d, RDMA Port: %d\n", TLS_PORT, RDMA_PORT);
    printf("Maximum clients: %d\n", MAX_CLIENTS);
    printf("Press Ctrl+C to stop\n\n");
    
    // Wait for shutdown
    while (g_server->running) {
        sleep(1);
        
        // Print status
        pthread_mutex_lock(&g_server->clients_mutex);
        if (g_server->num_clients > 0) {
            printf("\rActive clients: %d ", g_server->num_clients);
            fflush(stdout);
        }
        pthread_mutex_unlock(&g_server->clients_mutex);
    }
    
    printf("\nShutting down server...\n");
    cleanup_server(g_server);
    
    return 0;
}