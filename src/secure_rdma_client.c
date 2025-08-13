/**
 * Secure RDMA Client
 * Features:
 * - TLS-based PSN exchange with server
 * - Secure RDMA connection establishment
 * - Support for various RDMA operations
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include "rdma_compat.h"
#include "tls_utils.h"

#define RDMA_PORT 4791
#define BUFFER_SIZE 4096
#define TIMEOUT_MS 5000

struct client_context {
    // TLS connection
    struct tls_connection *tls_conn;
    uint32_t local_psn;
    uint32_t remote_psn;
    
    // RDMA resources - pure IB verbs
    struct ibv_context *ctx;      // IB device context
    struct ibv_pd *pd;
    struct ibv_qp *qp;
    struct ibv_cq *send_cq;
    struct ibv_cq *recv_cq;
    struct ibv_mr *send_mr;
    struct ibv_mr *recv_mr;
    char *send_buffer;
    char *recv_buffer;
    
    // Remote connection info
    struct rdma_conn_params remote_params;
    
    // Client state
    volatile int connected;
    volatile int running;
};

static struct client_context *g_client = NULL;

// Signal handler
static void signal_handler(int sig) {
    printf("\nReceived signal %d, disconnecting...\n", sig);
    if (g_client) {
        g_client->running = 0;
    }
}

// Initialize RDMA resources
static int init_rdma_resources(struct client_context *client) {
    // Allocate buffers
    client->send_buffer = calloc(1, BUFFER_SIZE);
    client->recv_buffer = calloc(1, BUFFER_SIZE);
    
    if (!client->send_buffer || !client->recv_buffer) {
        perror("Failed to allocate buffers");
        return -1;
    }
    
    // With pure IB verbs, PD and QP are already created directly
    // No need to get them from cm_id
    
    // Register memory regions
    client->send_mr = ibv_reg_mr(client->pd, client->send_buffer, BUFFER_SIZE,
                                 IBV_ACCESS_LOCAL_WRITE | IBV_ACCESS_REMOTE_READ);
    client->recv_mr = ibv_reg_mr(client->pd, client->recv_buffer, BUFFER_SIZE,
                                 IBV_ACCESS_LOCAL_WRITE | IBV_ACCESS_REMOTE_WRITE);
    
    if (!client->send_mr || !client->recv_mr) {
        perror("Failed to register memory");
        return -1;
    }
    
    printf("RDMA resources initialized\n");
    return 0;
}

// Setup QP with secure PSN
static int setup_qp_with_psn(struct client_context *client) {
    struct ibv_qp_attr attr;
    int flags;
    
    // Get port attributes (use port 1 as default)
    struct ibv_port_attr port_attr;
    if (ibv_query_port(client->ctx, 1, &port_attr)) {
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
    
    // Query GID (use port 1, index 0)
    if (ibv_query_gid(client->ctx, 1, 0, (union ibv_gid*)local_params.gid)) {
        perror("ibv_query_gid");
        return -1;
    }
    
    // Exchange RDMA parameters over TLS
    // Client receives first (from server's send), then sends (to server's receive)
    printf("Client: Waiting to receive RDMA params from server\n");
    if (receive_rdma_params(client->tls_conn, &client->remote_params) < 0) {
        fprintf(stderr, "Failed to receive RDMA parameters\n");
        return -1;
    }
    
    printf("Client: Sending RDMA params to server\n");
    if (send_rdma_params(client->tls_conn, &local_params) < 0) {
        fprintf(stderr, "Failed to send RDMA parameters\n");
        return -1;
    }
    printf("Client: RDMA params exchange complete\n");
    
    printf("QP %d <-> QP %d, PSN 0x%06x <-> 0x%06x\n",
           local_params.qp_num, client->remote_params.qp_num,
           client->local_psn, client->remote_psn);
    
    // Manual QP state transitions with custom PSN
    // We don't use rdma_connect() to have control over PSN values
    
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
        perror("Failed to modify QP to INIT");
        return -1;
    }
    printf("Client: QP transitioned to INIT\n");
    
    // Step 2: Transition QP to RTR (Ready to Receive) with remote PSN
    memset(&attr, 0, sizeof(attr));
    attr.qp_state = IBV_QPS_RTR;
    attr.path_mtu = IBV_MTU_1024;
    attr.dest_qp_num = client->remote_params.qp_num;
    attr.rq_psn = client->remote_psn;  // Use secure PSN from server
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
        perror("Failed to modify QP to RTR");
        return -1;
    }
    printf("Client: QP transitioned to RTR with remote PSN 0x%06x\n", client->remote_psn);
    
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
        perror("Failed to modify QP to RTS");
        return -1;
    }
    
    printf("Client: QP transitioned to RTS with local PSN 0x%06x\n", client->local_psn);
    return 0;
}

// Post receive buffer
static int post_receive(struct client_context *client) {
    struct ibv_sge sge;
    struct ibv_recv_wr wr, *bad_wr;
    
    memset(&sge, 0, sizeof(sge));
    sge.addr = (uintptr_t)client->recv_buffer;
    sge.length = BUFFER_SIZE;
    sge.lkey = client->recv_mr->lkey;
    
    memset(&wr, 0, sizeof(wr));
    wr.wr_id = 0;
    wr.sg_list = &sge;
    wr.num_sge = 1;
    
    if (ibv_post_recv(client->qp, &wr, &bad_wr)) {
        perror("ibv_post_recv");
        return -1;
    }
    
    return 0;
}

// Send message to server
static int send_message(struct client_context *client, const char *message) {
    struct ibv_sge sge;
    struct ibv_send_wr wr, *bad_wr;
    struct ibv_wc wc;
    
    strcpy(client->send_buffer, message);
    
    memset(&sge, 0, sizeof(sge));
    sge.addr = (uintptr_t)client->send_buffer;
    sge.length = strlen(message) + 1;
    sge.lkey = client->send_mr->lkey;
    
    memset(&wr, 0, sizeof(wr));
    wr.wr_id = 0;
    wr.opcode = IBV_WR_SEND;
    wr.sg_list = &sge;
    wr.num_sge = 1;
    wr.send_flags = IBV_SEND_SIGNALED;
    
    if (ibv_post_send(client->qp, &wr, &bad_wr)) {
        perror("ibv_post_send");
        return -1;
    }
    
    // Wait for completion
    while (ibv_poll_cq(client->send_cq, 1, &wc) == 0);
    
    if (wc.status != IBV_WC_SUCCESS) {
        fprintf(stderr, "Send failed with status: %s\n",
                ibv_wc_status_str(wc.status));
        return -1;
    }
    
    printf("Sent: %s\n", message);
    return 0;
}

// Receive message from server
static int receive_message(struct client_context *client) {
    struct ibv_wc wc;
    
    // Poll for completion
    while (ibv_poll_cq(client->recv_cq, 1, &wc) == 0) {
        if (!client->running) return -1;
        usleep(1000);
    }
    
    if (wc.status != IBV_WC_SUCCESS) {
        fprintf(stderr, "Receive failed with status: %s\n",
                ibv_wc_status_str(wc.status));
        return -1;
    }
    
    printf("Received: %s\n", client->recv_buffer);
    
    // Post another receive
    return post_receive(client);
}

// RDMA write operation
static int rdma_write_to_server(struct client_context *client, const char *data) {
    struct ibv_sge sge;
    struct ibv_send_wr wr, *bad_wr;
    struct ibv_wc wc;
    
    strcpy(client->send_buffer, data);
    
    memset(&sge, 0, sizeof(sge));
    sge.addr = (uintptr_t)client->send_buffer;
    sge.length = strlen(data) + 1;
    sge.lkey = client->send_mr->lkey;
    
    memset(&wr, 0, sizeof(wr));
    wr.wr_id = 0;
    wr.opcode = IBV_WR_RDMA_WRITE;
    wr.sg_list = &sge;
    wr.num_sge = 1;
    wr.send_flags = IBV_SEND_SIGNALED;
    wr.wr.rdma.remote_addr = client->remote_params.remote_addr;
    wr.wr.rdma.rkey = client->remote_params.rkey;
    
    if (ibv_post_send(client->qp, &wr, &bad_wr)) {
        perror("ibv_post_send (RDMA write)");
        return -1;
    }
    
    // Wait for completion
    while (ibv_poll_cq(client->send_cq, 1, &wc) == 0);
    
    if (wc.status != IBV_WC_SUCCESS) {
        fprintf(stderr, "RDMA write failed with status: %s\n",
                ibv_wc_status_str(wc.status));
        return -1;
    }
    
    printf("RDMA Write completed: %s\n", data);
    return 0;
}

// Create RDMA resources using pure IB verbs (no RDMA CM)
static int create_rdma_resources(struct client_context *client) {
    struct ibv_device **dev_list;
    int num_devices;
    
    // Get device list
    dev_list = ibv_get_device_list(&num_devices);
    if (!dev_list || num_devices == 0) {
        fprintf(stderr, "No RDMA devices found\n");
        return -1;
    }
    
    printf("Found %d RDMA device(s)\n", num_devices);
    
    // Open first device
    client->ctx = ibv_open_device(dev_list[0]);
    ibv_free_device_list(dev_list);
    
    if (!client->ctx) {
        fprintf(stderr, "Failed to open RDMA device\n");
        return -1;
    }
    
    printf("Opened RDMA device: %s\n", ibv_get_device_name(client->ctx->device));
    
    // Create protection domain
    client->pd = ibv_alloc_pd(client->ctx);
    if (!client->pd) {
        perror("ibv_alloc_pd");
        ibv_close_device(client->ctx);
        return -1;
    }
    
    // Create completion queues
    client->send_cq = ibv_create_cq(client->ctx, 10, NULL, NULL, 0);
    client->recv_cq = ibv_create_cq(client->ctx, 10, NULL, NULL, 0);
    
    if (!client->send_cq || !client->recv_cq) {
        fprintf(stderr, "Failed to create CQ\n");
        if (client->send_cq) ibv_destroy_cq(client->send_cq);
        if (client->recv_cq) ibv_destroy_cq(client->recv_cq);
        ibv_dealloc_pd(client->pd);
        ibv_close_device(client->ctx);
        return -1;
    }
    
    // Create Queue Pair
    struct ibv_qp_init_attr qp_attr;
    memset(&qp_attr, 0, sizeof(qp_attr));
    qp_attr.send_cq = client->send_cq;
    qp_attr.recv_cq = client->recv_cq;
    qp_attr.qp_type = IBV_QPT_RC;
    qp_attr.cap.max_send_wr = 10;
    qp_attr.cap.max_recv_wr = 10;
    qp_attr.cap.max_send_sge = 1;
    qp_attr.cap.max_recv_sge = 1;
    
    client->qp = ibv_create_qp(client->pd, &qp_attr);
    if (!client->qp) {
        perror("ibv_create_qp");
        ibv_destroy_cq(client->send_cq);
        ibv_destroy_cq(client->recv_cq);
        ibv_dealloc_pd(client->pd);
        ibv_close_device(client->ctx);
        return -1;
    }
    
    printf("Created QP with QPN: %d\n", client->qp->qp_num);
    
    // Initialize buffers and memory regions
    if (init_rdma_resources(client) < 0) {
        ibv_destroy_qp(client->qp);
        ibv_destroy_cq(client->send_cq);
        ibv_destroy_cq(client->recv_cq);
        ibv_dealloc_pd(client->pd);
        ibv_close_device(client->ctx);
        return -1;
    }
    
    printf("RDMA resources created successfully\n");
    client->connected = 1;
    
    return 0;
}

// Interactive client loop
static void run_interactive_client(struct client_context *client) {
    char input[256];
    int message_num = 1;
    
    printf("\n=== Secure RDMA Client ===\n");
    printf("Commands:\n");
    printf("  send <message>  - Send message to server\n");
    printf("  write <message> - RDMA write to server\n");
    printf("  auto            - Send automatic test messages\n");
    printf("  quit            - Exit client\n\n");
    
    // Post initial receives
    for (int i = 0; i < 5; i++) {
        post_receive(client);
    }
    
    // Receive welcome message
    receive_message(client);
    
    while (client->running && client->connected) {
        printf("> ");
        fflush(stdout);
        
        if (!fgets(input, sizeof(input), stdin)) {
            break;
        }
        
        // Remove newline
        input[strcspn(input, "\n")] = 0;
        
        if (strncmp(input, "send ", 5) == 0) {
            if (send_message(client, input + 5) == 0) {
                receive_message(client);
            }
        } else if (strncmp(input, "write ", 6) == 0) {
            rdma_write_to_server(client, input + 6);
        } else if (strcmp(input, "auto") == 0) {
            printf("Sending automatic test messages...\n");
            for (int i = 0; i < 5; i++) {
                char msg[128];
                snprintf(msg, sizeof(msg), "Test message %d (PSN: 0x%06x)", 
                        message_num++, client->local_psn);
                
                if (send_message(client, msg) == 0) {
                    receive_message(client);
                }
                
                sleep(1);
            }
        } else if (strcmp(input, "quit") == 0) {
            break;
        } else if (strlen(input) > 0) {
            printf("Unknown command. Try 'send <message>', 'write <message>', 'auto', or 'quit'\n");
        }
    }
}

// Cleanup client resources
static void cleanup_client(struct client_context *client) {
    if (!client) return;
    
    // Clean up RDMA resources
    if (client->send_mr) ibv_dereg_mr(client->send_mr);
    if (client->recv_mr) ibv_dereg_mr(client->recv_mr);
    
    // Clean up pure IB verbs resources
    if (client->qp) ibv_destroy_qp(client->qp);
    if (client->send_cq) ibv_destroy_cq(client->send_cq);
    if (client->recv_cq) ibv_destroy_cq(client->recv_cq);
    if (client->pd) ibv_dealloc_pd(client->pd);
    if (client->ctx) ibv_close_device(client->ctx);
    
    free(client->send_buffer);
    free(client->recv_buffer);
    
    // Close TLS connection
    if (client->tls_conn) {
        close_tls_connection(client->tls_conn);
    }
    
    cleanup_openssl();
    free(client);
}

int main(int argc, char *argv[]) {
    if (argc != 3) {
        fprintf(stderr, "Usage: %s <server_address> <server_name>\n", argv[0]);
        fprintf(stderr, "Example: %s 192.168.1.100 server.example.com\n", argv[0]);
        fprintf(stderr, "For localhost: %s 127.0.0.1 localhost\n", argv[0]);
        return 1;
    }
    
    const char *server_addr = argv[1];
    const char *server_name = argv[2];
    
    // Setup signal handler
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);
    
    // Initialize client
    g_client = calloc(1, sizeof(*g_client));
    if (!g_client) {
        fprintf(stderr, "Failed to allocate client context\n");
        return 1;
    }
    g_client->running = 1;
    
    // Initialize OpenSSL
    init_openssl();
    
    printf("Connecting to server %s (%s)...\n", server_name, server_addr);
    
    // Establish TLS connection
    g_client->tls_conn = connect_tls_server(server_name, TLS_PORT);
    if (!g_client->tls_conn) {
        fprintf(stderr, "Failed to establish TLS connection\n");
        cleanup_client(g_client);
        return 1;
    }
    
    // Exchange PSN over TLS
    if (exchange_psn_client(g_client->tls_conn, 
                          &g_client->local_psn, 
                          &g_client->remote_psn) < 0) {
        fprintf(stderr, "Failed to exchange PSN\n");
        cleanup_client(g_client);
        return 1;
    }
    
    // Create RDMA resources (pure IB verbs - no RDMA CM)
    if (create_rdma_resources(g_client) < 0) {
        fprintf(stderr, "Failed to create RDMA resources\n");
        cleanup_client(g_client);
        return 1;
    }
    
    // Setup QP with secure PSN
    if (setup_qp_with_psn(g_client) < 0) {
        fprintf(stderr, "Failed to setup QP with PSN\n");
        cleanup_client(g_client);
        return 1;
    }
    
    printf("Secure RDMA connection established!\n");
    printf("Local PSN: 0x%06x, Server PSN: 0x%06x\n", 
           g_client->local_psn, g_client->remote_psn);
    
    // Run interactive client
    run_interactive_client(g_client);
    
    printf("Disconnecting...\n");
    cleanup_client(g_client);
    
    return 0;
}