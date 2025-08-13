/**
 * Mock RDMA Implementation for Testing
 * Simulates RDMA operations using TCP sockets
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <pthread.h>
#include <errno.h>

#ifdef USE_MOCK_RDMA

#include "rdma_compat.h"

// Simulated RDMA device
static struct {
    char name[64];
    int initialized;
} mock_device = {"mock_rdma_0", 0};

// Mock implementations
struct ibv_device **ibv_get_device_list(int *num_devices) {
    static struct ibv_device *devices[2];
    static struct ibv_device device;
    
    if (!mock_device.initialized) {
        memcpy(&device, &mock_device, sizeof(device));
        devices[0] = &device;
        devices[1] = NULL;
        mock_device.initialized = 1;
    }
    
    if (num_devices) *num_devices = 1;
    return devices;
}

void ibv_free_device_list(struct ibv_device **list) {
    // No-op for mock
}

struct ibv_context *ibv_open_device(struct ibv_device *device) {
    struct ibv_context *ctx = calloc(1, sizeof(*ctx));
    if (ctx) {
        ctx->device = device;
    }
    return ctx;
}

int ibv_close_device(struct ibv_context *context) {
    free(context);
    return 0;
}

struct ibv_pd *ibv_alloc_pd(struct ibv_context *context) {
    struct ibv_pd *pd = calloc(1, sizeof(*pd));
    if (pd) {
        pd->context = context;
        pd->handle = rand();
    }
    return pd;
}

int ibv_dealloc_pd(struct ibv_pd *pd) {
    free(pd);
    return 0;
}

struct ibv_mr *ibv_reg_mr(struct ibv_pd *pd, void *addr, size_t length, int access) {
    struct ibv_mr *mr = calloc(1, sizeof(*mr));
    if (mr) {
        mr->pd = pd;
        mr->addr = addr;
        mr->length = length;
        mr->lkey = rand();
        mr->rkey = rand();
    }
    return mr;
}

int ibv_dereg_mr(struct ibv_mr *mr) {
    free(mr);
    return 0;
}

struct ibv_cq *ibv_create_cq(struct ibv_context *context, int cqe, 
                             void *cq_context, void *channel, int comp_vector) {
    struct ibv_cq *cq = calloc(1, sizeof(*cq));
    if (cq) {
        cq->context = context;
        cq->cqe = cqe;
        pthread_mutex_init(&cq->lock, NULL);
    }
    return cq;
}

int ibv_destroy_cq(struct ibv_cq *cq) {
    pthread_mutex_destroy(&cq->lock);
    free(cq);
    return 0;
}

int ibv_poll_cq(struct ibv_cq *cq, int num_entries, struct ibv_wc *wc) {
    // Simulate successful completion
    if (num_entries > 0 && wc) {
        wc[0].status = 0; // SUCCESS
        wc[0].wr_id = 0;
        return 1;
    }
    return 0;
}

// Mock RDMA CM functions
struct rdma_event_channel *rdma_create_event_channel(void) {
    struct rdma_event_channel *channel = calloc(1, sizeof(*channel));
    if (channel) {
        // Create a pipe for event simulation
        int fds[2];
        if (pipe(fds) == 0) {
            channel->fd = fds[0];
            // Write side is fds[1] - close it for now
            close(fds[1]);
        } else {
            // If pipe fails, just use stdin fd as placeholder
            channel->fd = 0;
        }
    }
    return channel;
}

void rdma_destroy_event_channel(struct rdma_event_channel *channel) {
    if (channel) {
        close(channel->fd);
        free(channel);
    }
}

int rdma_create_id(struct rdma_event_channel *channel, 
                   struct rdma_cm_id **id, void *context, enum rdma_port_space ps) {
    (void)ps;  // Unused in mock
    *id = calloc(1, sizeof(**id));
    if (*id) {
        (*id)->channel = channel;
        (*id)->context = context;
        (*id)->port_num = 1;
        return 0;
    }
    return -1;
}

int rdma_destroy_id(struct rdma_cm_id *id) {
    free(id);
    return 0;
}

int rdma_bind_addr(struct rdma_cm_id *id, struct sockaddr *addr) {
    // Simulate bind
    memcpy(&id->route.addr.src_addr, addr, sizeof(struct sockaddr_storage));
    return 0;
}

int rdma_listen(struct rdma_cm_id *id, int backlog) {
    // Simulate listen
    return 0;
}

int rdma_resolve_addr(struct rdma_cm_id *id, struct sockaddr *src_addr,
                     struct sockaddr *dst_addr, int timeout_ms) {
    // Simulate address resolution
    if (dst_addr) {
        memcpy(&id->route.addr.dst_addr, dst_addr, sizeof(struct sockaddr_storage));
    }
    return 0;
}

int rdma_resolve_route(struct rdma_cm_id *id, int timeout_ms) {
    // Simulate route resolution
    return 0;
}

int rdma_connect(struct rdma_cm_id *id, struct rdma_conn_param *param) {
    // Simulate connection
    return 0;
}

int rdma_accept(struct rdma_cm_id *id, struct rdma_conn_param *param) {
    // Simulate accept
    return 0;
}

int rdma_disconnect(struct rdma_cm_id *id) {
    // Simulate disconnect
    return 0;
}

int rdma_create_qp(struct rdma_cm_id *id, struct ibv_pd *pd,
                   struct ibv_qp_init_attr *qp_init_attr) {
    // Create mock QP
    struct ibv_qp *qp = calloc(1, sizeof(*qp));
    if (qp) {
        qp->qp_num = rand() & 0xFFFFFF;
        qp->state = 0; // RESET
        qp->pd = pd;
        qp->send_cq = qp_init_attr->send_cq;
        qp->recv_cq = qp_init_attr->recv_cq;
        pthread_mutex_init(&qp->lock, NULL);
        id->qp = qp;
        return 0;
    }
    return -1;
}

// Additional mock functions for completions
int ibv_post_send(struct ibv_qp *qp, struct ibv_send_wr *wr,
                  struct ibv_send_wr **bad_wr) {
    // Simulate successful send
    return 0;
}

int ibv_post_recv(struct ibv_qp *qp, struct ibv_recv_wr *wr,
                  struct ibv_recv_wr **bad_wr) {
    // Simulate successful receive
    return 0;
}

int ibv_modify_qp(struct ibv_qp *qp, struct ibv_qp_attr *attr, int attr_mask) {
    // Simulate QP state transitions
    if (attr_mask & (1 << 0)) { // IBV_QP_STATE
        qp->state = attr->qp_state;
    }
    return 0;
}

int ibv_query_port(struct ibv_context *context, uint8_t port_num,
                   struct ibv_port_attr *port_attr) {
    // Return mock port attributes
    if (port_attr) {
        port_attr->lid = 1;
        port_attr->state = 4; // ACTIVE
        port_attr->link_layer = 1; // IB
    }
    return 0;
}

int ibv_query_gid(struct ibv_context *context, uint8_t port_num,
                  int index, union ibv_gid *gid) {
    // Return mock GID
    if (gid) {
        memset(gid, 0, sizeof(*gid));
        gid->raw[0] = 0xfe;
        gid->raw[1] = 0x80;
    }
    return 0;
}

// Mock event handling
int rdma_get_cm_event(struct rdma_event_channel *channel,
                     struct rdma_cm_event **event) {
    (void)channel;
    // For server, simulate blocking - return -1 to indicate no events
    // This prevents the server from spinning in the event loop
    usleep(100000); // Sleep 100ms to avoid CPU spinning
    errno = EAGAIN;
    return -1;
}

int rdma_ack_cm_event(struct rdma_cm_event *event) {
    free(event);
    return 0;
}

const char *rdma_event_str(enum rdma_cm_event_type event) {
    switch (event) {
        case RDMA_CM_EVENT_ADDR_RESOLVED: return "ADDR_RESOLVED";
        case RDMA_CM_EVENT_ROUTE_RESOLVED: return "ROUTE_RESOLVED";
        case RDMA_CM_EVENT_CONNECT_REQUEST: return "CONNECT_REQUEST";
        case RDMA_CM_EVENT_ESTABLISHED: return "ESTABLISHED";
        case RDMA_CM_EVENT_DISCONNECTED: return "DISCONNECTED";
        default: return "UNKNOWN";
    }
}

const char *ibv_wc_status_str(enum ibv_wc_status status) {
    return status == 0 ? "SUCCESS" : "ERROR";
}

uint16_t rdma_get_src_port(struct rdma_cm_id *id) {
    struct sockaddr_in *addr = (struct sockaddr_in *)&id->route.addr.src_addr;
    return ntohs(addr->sin_port);
}

int ibv_destroy_qp(struct ibv_qp *qp) {
    if (qp) {
        pthread_mutex_destroy(&qp->lock);
        free(qp);
    }
    return 0;
}

// Memory registration helpers for rdma_reg_msgs
struct ibv_mr *rdma_reg_msgs(struct rdma_cm_id *id, void *addr, size_t length) {
    if (!id || !id->pd) {
        // Create a mock PD if needed
        struct ibv_context *ctx = calloc(1, sizeof(*ctx));
        id->pd = ibv_alloc_pd(ctx);
        id->verbs = ctx;
    }
    return ibv_reg_mr(id->pd, addr, length, IBV_ACCESS_LOCAL_WRITE);
}

int rdma_dereg_mr(struct ibv_mr *mr) {
    return ibv_dereg_mr(mr);
}

// Mock rdma_post functions
int rdma_post_send(struct rdma_cm_id *id, void *context, void *addr,
                   size_t length, struct ibv_mr *mr, int flags) {
    // Simulate send
    return 0;
}

int rdma_post_recv(struct rdma_cm_id *id, void *context, void *addr,
                   size_t length, struct ibv_mr *mr) {
    // Simulate receive
    return 0;
}

int rdma_post_write(struct rdma_cm_id *id, void *context, void *addr,
                    size_t length, struct ibv_mr *mr, int flags,
                    uint64_t remote_addr, uint32_t rkey) {
    // Simulate RDMA write
    return 0;
}

int rdma_post_read(struct rdma_cm_id *id, void *context, void *addr,
                   size_t length, struct ibv_mr *mr, int flags,
                   uint64_t remote_addr, uint32_t rkey) {
    // Simulate RDMA read
    return 0;
}

#endif // USE_MOCK_RDMA