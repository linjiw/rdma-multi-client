/**
 * RDMA Performance Test Client
 * Actual RDMA implementation for performance testing
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <time.h>
#include <sys/time.h>
#include <errno.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include "rdma_compat.h"
#include "tls_utils.h"

#define BUFFER_SIZE 4096
#define DEFAULT_PORT 4791

// Performance metrics for each client
struct client_metrics {
    struct timeval connect_start;
    struct timeval connect_end;
    struct timeval first_msg;
    struct timeval last_msg;
    
    int messages_sent;
    int messages_received;
    int errors;
    double total_latency_ms;
};

// RDMA client context
struct rdma_client_context {
    int client_id;
    char *server_ip;
    char *server_name;
    
    // TLS connection
    struct tls_connection *tls_conn;
    uint32_t local_psn;
    uint32_t remote_psn;
    
    // RDMA resources - pure IB verbs
    struct ibv_device **dev_list;
    struct ibv_context *ctx;
    struct ibv_pd *pd;
    struct ibv_qp *qp;
    struct ibv_cq *send_cq;
    struct ibv_cq *recv_cq;
    struct ibv_mr *send_mr;
    struct ibv_mr *recv_mr;
    char *send_buffer;
    char *recv_buffer;
    
    // Remote connection info
    struct rdma_conn_params local_params;
    struct rdma_conn_params remote_params;
    
    // Performance metrics
    struct client_metrics metrics;
};

// Get device GID
static int get_device_gid(struct ibv_context *ctx, union ibv_gid *gid) {
    struct ibv_device_attr device_attr;
    if (ibv_query_device(ctx, &device_attr)) {
        perror("ibv_query_device");
        return -1;
    }
    
    // Use first port, first GID
    if (ibv_query_gid(ctx, 1, 0, gid)) {
        perror("ibv_query_gid");
        return -1;
    }
    
    return 0;
}

// Create RDMA resources using pure IB verbs
static int create_rdma_resources(struct rdma_client_context *client) {
    // Get device list
    int num_devices;
    client->dev_list = ibv_get_device_list(&num_devices);
    if (!client->dev_list || num_devices == 0) {
        fprintf(stderr, "No RDMA devices found\n");
        return -1;
    }
    
    // Open first device
    client->ctx = ibv_open_device(client->dev_list[0]);
    if (!client->ctx) {
        fprintf(stderr, "Failed to open device\n");
        return -1;
    }
    
    // Allocate PD
    client->pd = ibv_alloc_pd(client->ctx);
    if (!client->pd) {
        fprintf(stderr, "Failed to allocate PD\n");
        return -1;
    }
    
    // Create CQs
    client->send_cq = ibv_create_cq(client->ctx, 10, NULL, NULL, 0);
    client->recv_cq = ibv_create_cq(client->ctx, 10, NULL, NULL, 0);
    if (!client->send_cq || !client->recv_cq) {
        fprintf(stderr, "Failed to create CQs\n");
        return -1;
    }
    
    // Create QP
    struct ibv_qp_init_attr qp_attr = {
        .send_cq = client->send_cq,
        .recv_cq = client->recv_cq,
        .qp_type = IBV_QPT_RC,
        .cap = {
            .max_send_wr = 10,
            .max_recv_wr = 10,
            .max_send_sge = 1,
            .max_recv_sge = 1,
            .max_inline_data = 256
        }
    };
    
    client->qp = ibv_create_qp(client->pd, &qp_attr);
    if (!client->qp) {
        fprintf(stderr, "Failed to create QP\n");
        return -1;
    }
    
    // Allocate and register buffers
    client->send_buffer = calloc(1, BUFFER_SIZE);
    client->recv_buffer = calloc(1, BUFFER_SIZE);
    if (!client->send_buffer || !client->recv_buffer) {
        fprintf(stderr, "Failed to allocate buffers\n");
        return -1;
    }
    
    int mr_flags = IBV_ACCESS_LOCAL_WRITE | IBV_ACCESS_REMOTE_READ | IBV_ACCESS_REMOTE_WRITE;
    client->send_mr = ibv_reg_mr(client->pd, client->send_buffer, BUFFER_SIZE, mr_flags);
    client->recv_mr = ibv_reg_mr(client->pd, client->recv_buffer, BUFFER_SIZE, mr_flags);
    if (!client->send_mr || !client->recv_mr) {
        fprintf(stderr, "Failed to register memory\n");
        return -1;
    }
    
    // Get local connection parameters
    union ibv_gid local_gid;
    if (get_device_gid(client->ctx, &local_gid) < 0) {
        return -1;
    }
    memcpy(client->local_params.gid, local_gid.raw, 16);
    client->local_params.qp_num = client->qp->qp_num;
    client->local_params.lid = 0;  // Not used in RoCE
    client->local_params.psn = client->local_psn;
    
    return 0;
}

// Transition QP to RTR (Ready to Receive)
static int modify_qp_to_rtr(struct rdma_client_context *client) {
    union ibv_gid remote_gid;
    memcpy(remote_gid.raw, client->remote_params.gid, 16);
    
    struct ibv_qp_attr attr = {
        .qp_state = IBV_QPS_RTR,
        .path_mtu = IBV_MTU_1024,
        .dest_qp_num = client->remote_params.qp_num,
        .rq_psn = client->remote_params.psn,  // Use remote PSN for receive
        .max_dest_rd_atomic = 1,
        .min_rnr_timer = 12,
        .ah_attr = {
            .is_global = 1,
            .grh = {
                .dgid = remote_gid,
                .sgid_index = 0,
                .hop_limit = 1
            },
            .dlid = client->remote_params.lid,
            .sl = 0,
            .src_path_bits = 0,
            .port_num = 1
        }
    };
    
    int flags = IBV_QP_STATE | IBV_QP_AV | IBV_QP_PATH_MTU |
                IBV_QP_DEST_QPN | IBV_QP_RQ_PSN |
                IBV_QP_MAX_DEST_RD_ATOMIC | IBV_QP_MIN_RNR_TIMER;
    
    if (ibv_modify_qp(client->qp, &attr, flags)) {
        fprintf(stderr, "Failed to modify QP to RTR\n");
        return -1;
    }
    
    return 0;
}

// Transition QP to RTS (Ready to Send)
static int modify_qp_to_rts(struct rdma_client_context *client) {
    struct ibv_qp_attr attr = {
        .qp_state = IBV_QPS_RTS,
        .timeout = 14,
        .retry_cnt = 7,
        .rnr_retry = 7,
        .sq_psn = client->local_psn,  // Use local PSN for send
        .max_rd_atomic = 1
    };
    
    int flags = IBV_QP_STATE | IBV_QP_TIMEOUT | IBV_QP_RETRY_CNT |
                IBV_QP_RNR_RETRY | IBV_QP_SQ_PSN | IBV_QP_MAX_QP_RD_ATOMIC;
    
    if (ibv_modify_qp(client->qp, &attr, flags)) {
        fprintf(stderr, "Failed to modify QP to RTS\n");
        return -1;
    }
    
    return 0;
}

// Helper to get SSL from TLS connection
static SSL* get_tls_ssl(struct tls_connection *conn) {
    return conn ? conn->ssl : NULL;
}

// Create TLS client connection
static struct tls_connection* create_tls_client_connection(const char *server_ip, int port) {
    return connect_tls_server(server_ip, port);
}

// Connect to server with TLS PSN exchange
static int connect_to_server(struct rdma_client_context *client) {
    // Record connection start time
    gettimeofday(&client->metrics.connect_start, NULL);
    
    // Create TLS connection for PSN exchange
    client->tls_conn = create_tls_client_connection(client->server_ip, TLS_PORT);
    if (!client->tls_conn) {
        fprintf(stderr, "Client %d: Failed to create TLS connection\n", client->client_id);
        return -1;
    }
    
    // Generate secure PSN
    client->local_psn = generate_secure_psn();
    
    // Exchange PSNs and parameters
    if (exchange_psn_client(client->tls_conn, &client->local_psn, &client->remote_psn) < 0) {
        fprintf(stderr, "Client %d: PSN exchange failed\n", client->client_id);
        return -1;
    }
    
    // Create RDMA resources
    if (create_rdma_resources(client) < 0) {
        fprintf(stderr, "Client %d: Failed to create RDMA resources\n", client->client_id);
        return -1;
    }
    
    // Exchange RDMA parameters
    SSL *ssl = get_tls_ssl(client->tls_conn);
    
    // Send local parameters
    if (SSL_write(ssl, &client->local_params, sizeof(client->local_params)) <= 0) {
        fprintf(stderr, "Client %d: Failed to send RDMA parameters\n", client->client_id);
        return -1;
    }
    
    // Receive remote parameters
    if (SSL_read(ssl, &client->remote_params, sizeof(client->remote_params)) <= 0) {
        fprintf(stderr, "Client %d: Failed to receive RDMA parameters\n", client->client_id);
        return -1;
    }
    
    // Transition QP to INIT
    struct ibv_qp_attr attr = {
        .qp_state = IBV_QPS_INIT,
        .pkey_index = 0,
        .port_num = 1,
        .qp_access_flags = IBV_ACCESS_LOCAL_WRITE | IBV_ACCESS_REMOTE_READ | IBV_ACCESS_REMOTE_WRITE
    };
    
    if (ibv_modify_qp(client->qp, &attr, IBV_QP_STATE | IBV_QP_PKEY_INDEX | 
                      IBV_QP_PORT | IBV_QP_ACCESS_FLAGS)) {
        fprintf(stderr, "Client %d: Failed to modify QP to INIT\n", client->client_id);
        return -1;
    }
    
    // Transition to RTR
    if (modify_qp_to_rtr(client) < 0) {
        return -1;
    }
    
    // Transition to RTS
    if (modify_qp_to_rts(client) < 0) {
        return -1;
    }
    
    // Record connection end time
    gettimeofday(&client->metrics.connect_end, NULL);
    
    return 0;
}

// Send RDMA message
static int send_rdma_message(struct rdma_client_context *client, const char *message, int size) {
    // Copy message to send buffer
    memcpy(client->send_buffer, message, size);
    
    // Post send
    struct ibv_sge sge = {
        .addr = (uintptr_t)client->send_buffer,
        .length = size,
        .lkey = client->send_mr->lkey
    };
    
    struct ibv_send_wr wr = {
        .wr_id = 1,
        .sg_list = &sge,
        .num_sge = 1,
        .opcode = IBV_WR_SEND,
        .send_flags = IBV_SEND_SIGNALED
    };
    
    struct ibv_send_wr *bad_wr;
    if (ibv_post_send(client->qp, &wr, &bad_wr)) {
        fprintf(stderr, "Client %d: Failed to post send\n", client->client_id);
        return -1;
    }
    
    // Wait for completion
    struct ibv_wc wc;
    int ne;
    do {
        ne = ibv_poll_cq(client->send_cq, 1, &wc);
    } while (ne == 0);
    
    if (ne < 0 || wc.status != IBV_WC_SUCCESS) {
        fprintf(stderr, "Client %d: Send failed with status %d\n", 
                client->client_id, wc.status);
        return -1;
    }
    
    client->metrics.messages_sent++;
    return 0;
}

// Post receive buffer
static int post_receive(struct rdma_client_context *client) {
    struct ibv_sge sge = {
        .addr = (uintptr_t)client->recv_buffer,
        .length = BUFFER_SIZE,
        .lkey = client->recv_mr->lkey
    };
    
    struct ibv_recv_wr wr = {
        .wr_id = 2,
        .sg_list = &sge,
        .num_sge = 1
    };
    
    struct ibv_recv_wr *bad_wr;
    if (ibv_post_recv(client->qp, &wr, &bad_wr)) {
        fprintf(stderr, "Client %d: Failed to post receive\n", client->client_id);
        return -1;
    }
    
    return 0;
}

// Run performance test for a single client
int run_rdma_client_test(int client_id, const char *server_ip, const char *server_name,
                         int num_messages, int message_size, int think_time_ms,
                         struct client_metrics *metrics) {
    struct rdma_client_context client = {0};
    client.client_id = client_id;
    client.server_ip = (char*)server_ip;
    client.server_name = (char*)server_name;
    
    // Connect to server
    if (connect_to_server(&client) < 0) {
        metrics->errors++;
        return -1;
    }
    
    // Prepare message
    char *message = malloc(message_size);
    memset(message, 'A' + (client_id % 26), message_size);
    
    // Record first message time
    gettimeofday(&client.metrics.first_msg, NULL);
    
    // Send messages
    for (int i = 0; i < num_messages; i++) {
        // Post receive first
        if (post_receive(&client) < 0) {
            client.metrics.errors++;
            break;
        }
        
        // Measure send latency
        struct timeval send_start, send_end;
        gettimeofday(&send_start, NULL);
        
        if (send_rdma_message(&client, message, message_size) < 0) {
            client.metrics.errors++;
            break;
        }
        
        gettimeofday(&send_end, NULL);
        
        // Calculate latency
        double latency = (send_end.tv_sec - send_start.tv_sec) * 1000.0 +
                        (send_end.tv_usec - send_start.tv_usec) / 1000.0;
        client.metrics.total_latency_ms += latency;
        
        // Think time
        if (think_time_ms > 0) {
            usleep(think_time_ms * 1000);
        }
    }
    
    // Record last message time
    gettimeofday(&client.metrics.last_msg, NULL);
    
    // Copy metrics
    *metrics = client.metrics;
    
    // Cleanup
    if (client.qp) ibv_destroy_qp(client.qp);
    if (client.send_mr) ibv_dereg_mr(client.send_mr);
    if (client.recv_mr) ibv_dereg_mr(client.recv_mr);
    if (client.send_cq) ibv_destroy_cq(client.send_cq);
    if (client.recv_cq) ibv_destroy_cq(client.recv_cq);
    if (client.pd) ibv_dealloc_pd(client.pd);
    if (client.ctx) ibv_close_device(client.ctx);
    if (client.dev_list) ibv_free_device_list(client.dev_list);
    if (client.tls_conn) close_tls_connection(client.tls_conn);
    free(client.send_buffer);
    free(client.recv_buffer);
    free(message);
    
    return 0;
}