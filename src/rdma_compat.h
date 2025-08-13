/**
 * RDMA Compatibility Header
 * Provides compatibility layer for systems without RDMA
 */

#ifndef RDMA_COMPAT_H
#define RDMA_COMPAT_H

#ifdef USE_MOCK_RDMA

// Mock RDMA implementation - define all structures and types
#include <pthread.h>
#include <stdint.h>
#include <sys/socket.h>

// Forward declarations
struct ibv_wc;
struct rdma_conn_param;

// Port space enum
enum rdma_port_space {
    RDMA_PS_IPOIB = 0x0002,
    RDMA_PS_IB    = 0x013F,
    RDMA_PS_TCP_VAL = 0x0106,
    RDMA_PS_UDP   = 0x0111
};

// Basic type definitions
union ibv_gid {
    uint8_t raw[16];
    struct {
        uint64_t subnet_prefix;
        uint64_t interface_id;
    } global;
};

// Define missing structures and types
struct ibv_device {
    char name[64];
    int index;
};

struct ibv_context {
    struct ibv_device *device;
    int num_comp_vectors;
};

struct ibv_pd {
    struct ibv_context *context;
    uint32_t handle;
};

struct ibv_mr {
    struct ibv_pd *pd;
    void *addr;
    size_t length;
    uint32_t lkey;
    uint32_t rkey;
};

struct ibv_cq {
    struct ibv_context *context;
    int cqe;
    pthread_mutex_t lock;
};

struct ibv_qp {
    uint32_t qp_num;
    int state;
    struct ibv_pd *pd;
    struct ibv_cq *send_cq;
    struct ibv_cq *recv_cq;
    pthread_mutex_t lock;
};

struct ibv_qp_init_attr {
    void *qp_context;
    struct ibv_cq *send_cq;
    struct ibv_cq *recv_cq;
    struct ibv_srq *srq;
    struct ibv_qp_cap {
        uint32_t max_send_wr;
        uint32_t max_recv_wr;
        uint32_t max_send_sge;
        uint32_t max_recv_sge;
        uint32_t max_inline_data;
    } cap;
    enum ibv_qp_type {
        IBV_QPT_RC = 2
    } qp_type;
    int sq_sig_all;
};

struct ibv_qp_attr {
    enum ibv_qp_state {
        IBV_QPS_RESET = 0,
        IBV_QPS_INIT = 1,
        IBV_QPS_RTR = 2,
        IBV_QPS_RTS = 3
    } qp_state;
    uint32_t port_num;
    uint32_t qp_access_flags;
    uint16_t pkey_index;
    enum ibv_mtu {
        IBV_MTU_1024 = 3
    } path_mtu;
    uint32_t dest_qp_num;
    uint32_t rq_psn;
    uint32_t sq_psn;
    uint32_t max_rd_atomic;
    uint32_t max_dest_rd_atomic;
    uint8_t min_rnr_timer;
    uint8_t timeout;
    uint8_t retry_cnt;
    uint8_t rnr_retry;
    struct ibv_ah_attr {
        struct ibv_global_route {
            union ibv_gid dgid;
            uint32_t flow_label;
            uint8_t sgid_index;
            uint8_t hop_limit;
            uint8_t traffic_class;
        } grh;
        uint16_t dlid;
        uint8_t sl;
        uint8_t src_path_bits;
        uint8_t static_rate;
        uint8_t is_global;
        uint8_t port_num;
    } ah_attr;
};

struct ibv_port_attr {
    uint16_t lid;
    uint32_t state;
    uint32_t link_layer;
};

struct ibv_wc {
    uint64_t wr_id;
    enum ibv_wc_status {
        IBV_WC_SUCCESS = 0
    } status;
    enum ibv_wc_opcode {
        IBV_WC_SEND = 0,
        IBV_WC_RDMA_WRITE = 1,
        IBV_WC_RDMA_READ = 2,
        IBV_WC_RECV = 128
    } opcode;
    uint32_t vendor_err;
    uint32_t byte_len;
    uint32_t qp_num;
};

struct ibv_sge {
    uint64_t addr;
    uint32_t length;
    uint32_t lkey;
};

struct ibv_send_wr {
    uint64_t wr_id;
    struct ibv_send_wr *next;
    struct ibv_sge *sg_list;
    int num_sge;
    enum ibv_wr_opcode {
        IBV_WR_SEND = 0,
        IBV_WR_RDMA_WRITE = 1,
        IBV_WR_RDMA_READ = 2
    } opcode;
    int send_flags;
    union {
        struct {
            uint64_t remote_addr;
            uint32_t rkey;
        } rdma;
    } wr;
};

struct ibv_recv_wr {
    uint64_t wr_id;
    struct ibv_recv_wr *next;
    struct ibv_sge *sg_list;
    int num_sge;
};

// RDMA CM structures
struct rdma_event_channel {
    int fd;
};

struct rdma_cm_id {
    struct rdma_event_channel *channel;
    void *context;
    struct ibv_qp *qp;
    struct ibv_pd *pd;
    struct ibv_context *verbs;
    struct ibv_cq *send_cq;
    struct ibv_cq *recv_cq;
    uint8_t port_num;
    struct rdma_route {
        struct rdma_addr {
            struct sockaddr_storage src_addr;
            struct sockaddr_storage dst_addr;
        } addr;
    } route;
};

struct rdma_cm_event {
    enum rdma_cm_event_type {
        RDMA_CM_EVENT_ADDR_RESOLVED,
        RDMA_CM_EVENT_ROUTE_RESOLVED,
        RDMA_CM_EVENT_CONNECT_REQUEST,
        RDMA_CM_EVENT_ESTABLISHED,
        RDMA_CM_EVENT_DISCONNECTED
    } event;
    struct rdma_cm_id *id;
    struct rdma_conn_param *param;
};

struct rdma_conn_param {
    const void *private_data;
    uint8_t private_data_len;
    uint8_t responder_resources;
    uint8_t initiator_depth;
    uint8_t flow_control;
    uint8_t retry_count;
    uint8_t rnr_retry_count;
    uint8_t srq;
    uint32_t qp_num;
};

// Define access flags
#define IBV_ACCESS_LOCAL_WRITE   (1<<0)
#define IBV_ACCESS_REMOTE_WRITE  (1<<1)
#define IBV_ACCESS_REMOTE_READ   (1<<2)

// Define QP state flags
#define IBV_QP_STATE             (1<<0)
#define IBV_QP_PKEY_INDEX        (1<<1)
#define IBV_QP_PORT              (1<<2)
#define IBV_QP_ACCESS_FLAGS      (1<<3)
#define IBV_QP_AV                (1<<4)
#define IBV_QP_PATH_MTU          (1<<5)
#define IBV_QP_DEST_QPN          (1<<6)
#define IBV_QP_RQ_PSN            (1<<7)
#define IBV_QP_MAX_DEST_RD_ATOMIC (1<<8)
#define IBV_QP_MIN_RNR_TIMER     (1<<9)
#define IBV_QP_SQ_PSN            (1<<10)
#define IBV_QP_TIMEOUT           (1<<11)
#define IBV_QP_RETRY_CNT         (1<<12)
#define IBV_QP_RNR_RETRY         (1<<13)
#define IBV_QP_MAX_QP_RD_ATOMIC  (1<<14)

// Define send flags
#define IBV_SEND_SIGNALED        (1<<1)

// Define link layers
#define IBV_LINK_LAYER_ETHERNET  1
#define IBV_LINK_LAYER_INFINIBAND 2

// Define RDMA PS
#define RDMA_PS_TCP              RDMA_PS_TCP_VAL

// Function declarations
struct ibv_device **ibv_get_device_list(int *num_devices);
void ibv_free_device_list(struct ibv_device **list);
struct ibv_context *ibv_open_device(struct ibv_device *device);
int ibv_close_device(struct ibv_context *context);
struct ibv_pd *ibv_alloc_pd(struct ibv_context *context);
int ibv_dealloc_pd(struct ibv_pd *pd);
struct ibv_mr *ibv_reg_mr(struct ibv_pd *pd, void *addr, size_t length, int access);
int ibv_dereg_mr(struct ibv_mr *mr);
struct ibv_cq *ibv_create_cq(struct ibv_context *context, int cqe, void *cq_context, void *channel, int comp_vector);
int ibv_destroy_cq(struct ibv_cq *cq);
int ibv_poll_cq(struct ibv_cq *cq, int num_entries, struct ibv_wc *wc);
int ibv_post_send(struct ibv_qp *qp, struct ibv_send_wr *wr, struct ibv_send_wr **bad_wr);
int ibv_post_recv(struct ibv_qp *qp, struct ibv_recv_wr *wr, struct ibv_recv_wr **bad_wr);
int ibv_modify_qp(struct ibv_qp *qp, struct ibv_qp_attr *attr, int attr_mask);
int ibv_query_port(struct ibv_context *context, uint8_t port_num, struct ibv_port_attr *port_attr);
int ibv_query_gid(struct ibv_context *context, uint8_t port_num, int index, union ibv_gid *gid);
int ibv_destroy_qp(struct ibv_qp *qp);

struct rdma_event_channel *rdma_create_event_channel(void);
void rdma_destroy_event_channel(struct rdma_event_channel *channel);
int rdma_create_id(struct rdma_event_channel *channel, struct rdma_cm_id **id, void *context, enum rdma_port_space ps);
int rdma_destroy_id(struct rdma_cm_id *id);
int rdma_bind_addr(struct rdma_cm_id *id, struct sockaddr *addr);
int rdma_listen(struct rdma_cm_id *id, int backlog);
int rdma_get_cm_event(struct rdma_event_channel *channel, struct rdma_cm_event **event);
int rdma_ack_cm_event(struct rdma_cm_event *event);
int rdma_resolve_addr(struct rdma_cm_id *id, struct sockaddr *src_addr, struct sockaddr *dst_addr, int timeout_ms);
int rdma_resolve_route(struct rdma_cm_id *id, int timeout_ms);
int rdma_connect(struct rdma_cm_id *id, struct rdma_conn_param *param);
int rdma_accept(struct rdma_cm_id *id, struct rdma_conn_param *param);
int rdma_disconnect(struct rdma_cm_id *id);
int rdma_create_qp(struct rdma_cm_id *id, struct ibv_pd *pd, struct ibv_qp_init_attr *qp_init_attr);
const char *rdma_event_str(enum rdma_cm_event_type event);
const char *ibv_wc_status_str(enum ibv_wc_status status);
uint16_t rdma_get_src_port(struct rdma_cm_id *id);

struct ibv_mr *rdma_reg_msgs(struct rdma_cm_id *id, void *addr, size_t length);
int rdma_dereg_mr(struct ibv_mr *mr);
int rdma_post_send(struct rdma_cm_id *id, void *context, void *addr, size_t length, struct ibv_mr *mr, int flags);
int rdma_post_recv(struct rdma_cm_id *id, void *context, void *addr, size_t length, struct ibv_mr *mr);
int rdma_post_write(struct rdma_cm_id *id, void *context, void *addr, size_t length, struct ibv_mr *mr, int flags, uint64_t remote_addr, uint32_t rkey);
int rdma_post_read(struct rdma_cm_id *id, void *context, void *addr, size_t length, struct ibv_mr *mr, int flags, uint64_t remote_addr, uint32_t rkey);


#else

// Use real RDMA headers
#include <rdma/rdma_cma.h>
#include <rdma/rdma_verbs.h>
#include <infiniband/verbs.h>

#endif // USE_MOCK_RDMA

#endif // RDMA_COMPAT_H