/**
 * Mock RDMA Library for Testing on Non-RDMA Systems
 * Simulates RDMA behavior using TCP sockets
 */

#ifndef MOCK_RDMA_H
#define MOCK_RDMA_H

#ifdef USE_MOCK_RDMA

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <pthread.h>
#include <errno.h>

// Mock RDMA types that mirror real ones
typedef struct mock_ibv_device {
    char name[64];
    int index;
} mock_ibv_device_t;

typedef struct mock_ibv_context {
    struct mock_ibv_device *device;
    int socket_fd;
} mock_ibv_context_t;

typedef struct mock_ibv_pd {
    struct mock_ibv_context *context;
    uint32_t handle;
} mock_ibv_pd_t;

typedef struct mock_ibv_mr {
    struct mock_ibv_pd *pd;
    void *addr;
    size_t length;
    uint32_t lkey;
    uint32_t rkey;
} mock_ibv_mr_t;

typedef struct mock_ibv_cq {
    struct mock_ibv_context *context;
    int cqe;
    pthread_mutex_t lock;
    void *completions[100];  // Simple completion queue
    int head;
    int tail;
} mock_ibv_cq_t;

typedef struct mock_ibv_qp {
    uint32_t qp_num;
    int state;
    struct mock_ibv_pd *pd;
    struct mock_ibv_cq *send_cq;
    struct mock_ibv_cq *recv_cq;
    int socket_fd;
    pthread_mutex_t lock;
} mock_ibv_qp_t;

// Mock RDMA CM types
typedef struct mock_rdma_event_channel {
    int fd;
} mock_rdma_event_channel_t;

typedef struct mock_rdma_cm_id {
    struct mock_rdma_event_channel *channel;
    void *context;
    struct mock_ibv_qp *qp;
    struct mock_ibv_pd *pd;
    struct mock_ibv_context *verbs;
    struct mock_ibv_cq *send_cq;
    struct mock_ibv_cq *recv_cq;
    int port_num;
    struct {
        struct {
            struct sockaddr_storage src_addr;
            struct sockaddr_storage dst_addr;
        } addr;
    } route;
} mock_rdma_cm_id_t;

// Mock enums
enum mock_ibv_qp_state {
    MOCK_IBV_QPS_RESET,
    MOCK_IBV_QPS_INIT,
    MOCK_IBV_QPS_RTR,
    MOCK_IBV_QPS_RTS
};

enum mock_rdma_cm_event_type {
    MOCK_RDMA_CM_EVENT_ADDR_RESOLVED,
    MOCK_RDMA_CM_EVENT_ROUTE_RESOLVED,
    MOCK_RDMA_CM_EVENT_CONNECT_REQUEST,
    MOCK_RDMA_CM_EVENT_ESTABLISHED,
    MOCK_RDMA_CM_EVENT_DISCONNECTED
};

// Type mappings for compatibility
#define ibv_device mock_ibv_device_t
#define ibv_context mock_ibv_context_t
#define ibv_pd mock_ibv_pd_t
#define ibv_mr mock_ibv_mr_t
#define ibv_cq mock_ibv_cq_t
#define ibv_qp mock_ibv_qp_t
#define rdma_event_channel mock_rdma_event_channel_t
#define rdma_cm_id mock_rdma_cm_id_t
#define rdma_cm_event mock_rdma_cm_event_t

#define IBV_QPS_RESET MOCK_IBV_QPS_RESET
#define IBV_QPS_INIT MOCK_IBV_QPS_INIT
#define IBV_QPS_RTR MOCK_IBV_QPS_RTR
#define IBV_QPS_RTS MOCK_IBV_QPS_RTS

#define RDMA_CM_EVENT_ADDR_RESOLVED MOCK_RDMA_CM_EVENT_ADDR_RESOLVED
#define RDMA_CM_EVENT_ROUTE_RESOLVED MOCK_RDMA_CM_EVENT_ROUTE_RESOLVED
#define RDMA_CM_EVENT_CONNECT_REQUEST MOCK_RDMA_CM_EVENT_CONNECT_REQUEST
#define RDMA_CM_EVENT_ESTABLISHED MOCK_RDMA_CM_EVENT_ESTABLISHED
#define RDMA_CM_EVENT_DISCONNECTED MOCK_RDMA_CM_EVENT_DISCONNECTED

// Mock function declarations
struct mock_ibv_device **mock_ibv_get_device_list(int *num_devices);
void mock_ibv_free_device_list(struct mock_ibv_device **list);
struct mock_ibv_context *mock_ibv_open_device(struct mock_ibv_device *device);
int mock_ibv_close_device(struct mock_ibv_context *context);
struct mock_ibv_pd *mock_ibv_alloc_pd(struct mock_ibv_context *context);
int mock_ibv_dealloc_pd(struct mock_ibv_pd *pd);
struct mock_ibv_mr *mock_ibv_reg_mr(struct mock_ibv_pd *pd, void *addr, size_t length, int access);
int mock_ibv_dereg_mr(struct mock_ibv_mr *mr);
struct mock_ibv_cq *mock_ibv_create_cq(struct mock_ibv_context *context, int cqe, void *cq_context, void *channel, int comp_vector);
int mock_ibv_destroy_cq(struct mock_ibv_cq *cq);
int mock_ibv_poll_cq(struct mock_ibv_cq *cq, int num_entries, struct ibv_wc *wc);

// RDMA CM mock functions
struct mock_rdma_event_channel *mock_rdma_create_event_channel(void);
void mock_rdma_destroy_event_channel(struct mock_rdma_event_channel *channel);
int mock_rdma_create_id(struct mock_rdma_event_channel *channel, struct mock_rdma_cm_id **id, void *context, int ps);
int mock_rdma_destroy_id(struct mock_rdma_cm_id *id);
int mock_rdma_bind_addr(struct mock_rdma_cm_id *id, struct sockaddr *addr);
int mock_rdma_listen(struct mock_rdma_cm_id *id, int backlog);
int mock_rdma_resolve_addr(struct mock_rdma_cm_id *id, struct sockaddr *src_addr, struct sockaddr *dst_addr, int timeout_ms);
int mock_rdma_resolve_route(struct mock_rdma_cm_id *id, int timeout_ms);
int mock_rdma_connect(struct mock_rdma_cm_id *id, struct rdma_conn_param *param);
int mock_rdma_accept(struct mock_rdma_cm_id *id, struct rdma_conn_param *param);
int mock_rdma_disconnect(struct mock_rdma_cm_id *id);

// Function name mappings
#define ibv_get_device_list mock_ibv_get_device_list
#define ibv_free_device_list mock_ibv_free_device_list
#define ibv_open_device mock_ibv_open_device
#define ibv_close_device mock_ibv_close_device
#define ibv_alloc_pd mock_ibv_alloc_pd
#define ibv_dealloc_pd mock_ibv_dealloc_pd
#define ibv_reg_mr mock_ibv_reg_mr
#define ibv_dereg_mr mock_ibv_dereg_mr
#define ibv_create_cq mock_ibv_create_cq
#define ibv_destroy_cq mock_ibv_destroy_cq
#define ibv_poll_cq mock_ibv_poll_cq

#define rdma_create_event_channel mock_rdma_create_event_channel
#define rdma_destroy_event_channel mock_rdma_destroy_event_channel
#define rdma_create_id mock_rdma_create_id
#define rdma_destroy_id mock_rdma_destroy_id
#define rdma_bind_addr mock_rdma_bind_addr
#define rdma_listen mock_rdma_listen
#define rdma_resolve_addr mock_rdma_resolve_addr
#define rdma_resolve_route mock_rdma_resolve_route
#define rdma_connect mock_rdma_connect
#define rdma_accept mock_rdma_accept
#define rdma_disconnect mock_rdma_disconnect

// Additional compatibility macros
#define IBV_WC_SUCCESS 0
#define IBV_SEND_SIGNALED 1
#define IBV_ACCESS_LOCAL_WRITE 1
#define IBV_ACCESS_REMOTE_READ 2
#define IBV_ACCESS_REMOTE_WRITE 4
#define RDMA_PS_TCP 1

#endif // USE_MOCK_RDMA

#endif // MOCK_RDMA_H