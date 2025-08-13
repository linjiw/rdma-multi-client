/**
 * test_pure_ib.c - Proof of concept for pure IB verbs implementation
 * This tests the core flow: device open, QP creation, and state transitions with custom PSN
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <infiniband/verbs.h>

#define TEST_PSN_LOCAL  0x123456
#define TEST_PSN_REMOTE 0x789ABC

int main() {
    struct ibv_device **dev_list;
    struct ibv_context *ctx;
    struct ibv_pd *pd;
    struct ibv_cq *cq;
    struct ibv_qp *qp;
    struct ibv_qp_init_attr qp_init_attr;
    struct ibv_qp_attr qp_attr;
    struct ibv_port_attr port_attr;
    int num_devices;
    int ret;

    printf("Pure IB Verbs Proof of Concept\n");
    printf("===============================\n\n");

    // Step 1: Get device list
    dev_list = ibv_get_device_list(&num_devices);
    if (!dev_list || num_devices == 0) {
        fprintf(stderr, "No IB devices found\n");
        return 1;
    }
    printf("✓ Found %d IB device(s)\n", num_devices);

    // Step 2: Open first device
    ctx = ibv_open_device(dev_list[0]);
    ibv_free_device_list(dev_list);
    
    if (!ctx) {
        fprintf(stderr, "Failed to open device\n");
        return 1;
    }
    printf("✓ Opened device: %s\n", ibv_get_device_name(ctx->device));

    // Step 3: Query port attributes
    if (ibv_query_port(ctx, 1, &port_attr)) {
        fprintf(stderr, "Failed to query port\n");
        ibv_close_device(ctx);
        return 1;
    }
    printf("✓ Port 1 state: %s\n", 
           port_attr.state == IBV_PORT_ACTIVE ? "ACTIVE" : "NOT ACTIVE");
    printf("  Link layer: %s\n",
           port_attr.link_layer == IBV_LINK_LAYER_ETHERNET ? "Ethernet (RoCE)" : "InfiniBand");

    // Step 4: Allocate Protection Domain
    pd = ibv_alloc_pd(ctx);
    if (!pd) {
        fprintf(stderr, "Failed to allocate PD\n");
        ibv_close_device(ctx);
        return 1;
    }
    printf("✓ Allocated Protection Domain\n");

    // Step 5: Create Completion Queue
    cq = ibv_create_cq(ctx, 10, NULL, NULL, 0);
    if (!cq) {
        fprintf(stderr, "Failed to create CQ\n");
        ibv_dealloc_pd(pd);
        ibv_close_device(ctx);
        return 1;
    }
    printf("✓ Created Completion Queue\n");

    // Step 6: Create Queue Pair
    memset(&qp_init_attr, 0, sizeof(qp_init_attr));
    qp_init_attr.send_cq = cq;
    qp_init_attr.recv_cq = cq;
    qp_init_attr.qp_type = IBV_QPT_RC;
    qp_init_attr.cap.max_send_wr = 10;
    qp_init_attr.cap.max_recv_wr = 10;
    qp_init_attr.cap.max_send_sge = 1;
    qp_init_attr.cap.max_recv_sge = 1;

    qp = ibv_create_qp(pd, &qp_init_attr);
    if (!qp) {
        fprintf(stderr, "Failed to create QP\n");
        ibv_destroy_cq(cq);
        ibv_dealloc_pd(pd);
        ibv_close_device(ctx);
        return 1;
    }
    printf("✓ Created Queue Pair (QPN: %d)\n", qp->qp_num);

    // Step 7: Transition QP to INIT state
    memset(&qp_attr, 0, sizeof(qp_attr));
    qp_attr.qp_state = IBV_QPS_INIT;
    qp_attr.port_num = 1;
    qp_attr.pkey_index = 0;
    qp_attr.qp_access_flags = IBV_ACCESS_LOCAL_WRITE | 
                              IBV_ACCESS_REMOTE_READ | 
                              IBV_ACCESS_REMOTE_WRITE;

    ret = ibv_modify_qp(qp, &qp_attr,
                       IBV_QP_STATE | IBV_QP_PKEY_INDEX | 
                       IBV_QP_PORT | IBV_QP_ACCESS_FLAGS);
    if (ret) {
        fprintf(stderr, "Failed to transition QP to INIT\n");
        goto cleanup;
    }
    printf("✓ QP transitioned to INIT state\n");

    // Step 8: Transition QP to RTR with custom remote PSN
    memset(&qp_attr, 0, sizeof(qp_attr));
    qp_attr.qp_state = IBV_QPS_RTR;
    qp_attr.path_mtu = IBV_MTU_1024;
    qp_attr.dest_qp_num = qp->qp_num;  // Using same QP for test
    qp_attr.rq_psn = TEST_PSN_REMOTE;  // Custom remote PSN
    qp_attr.max_dest_rd_atomic = 1;
    qp_attr.min_rnr_timer = 12;
    
    // Address handle attributes
    qp_attr.ah_attr.is_global = 0;
    qp_attr.ah_attr.dlid = port_attr.lid;
    qp_attr.ah_attr.sl = 0;
    qp_attr.ah_attr.src_path_bits = 0;
    qp_attr.ah_attr.port_num = 1;
    
    // For RoCE, we need GID
    if (port_attr.link_layer == IBV_LINK_LAYER_ETHERNET) {
        union ibv_gid gid;
        
        // Query local GID
        if (ibv_query_gid(ctx, 1, 0, &gid)) {
            fprintf(stderr, "Failed to query GID\n");
            goto cleanup;
        }
        
        qp_attr.ah_attr.is_global = 1;
        qp_attr.ah_attr.grh.hop_limit = 1;
        memcpy(qp_attr.ah_attr.grh.dgid.raw, gid.raw, 16);  // Use local GID for test
        qp_attr.ah_attr.grh.sgid_index = 0;
        printf("  RoCE detected, using local GID for loopback test\n");
    }

    ret = ibv_modify_qp(qp, &qp_attr,
                       IBV_QP_STATE | IBV_QP_AV | IBV_QP_PATH_MTU |
                       IBV_QP_DEST_QPN | IBV_QP_RQ_PSN |
                       IBV_QP_MAX_DEST_RD_ATOMIC | IBV_QP_MIN_RNR_TIMER);
    if (ret) {
        fprintf(stderr, "Failed to transition QP to RTR\n");
        goto cleanup;
    }
    printf("✓ QP transitioned to RTR with remote PSN: 0x%06x\n", TEST_PSN_REMOTE);

    // Step 9: Transition QP to RTS with custom local PSN
    memset(&qp_attr, 0, sizeof(qp_attr));
    qp_attr.qp_state = IBV_QPS_RTS;
    qp_attr.sq_psn = TEST_PSN_LOCAL;  // Custom local PSN
    qp_attr.timeout = 14;
    qp_attr.retry_cnt = 7;
    qp_attr.rnr_retry = 7;
    qp_attr.max_rd_atomic = 1;

    ret = ibv_modify_qp(qp, &qp_attr,
                       IBV_QP_STATE | IBV_QP_TIMEOUT | IBV_QP_RETRY_CNT |
                       IBV_QP_RNR_RETRY | IBV_QP_SQ_PSN | IBV_QP_MAX_QP_RD_ATOMIC);
    if (ret) {
        fprintf(stderr, "Failed to transition QP to RTS\n");
        goto cleanup;
    }
    printf("✓ QP transitioned to RTS with local PSN: 0x%06x\n", TEST_PSN_LOCAL);

    // Verify final state
    struct ibv_qp_attr check_attr;
    struct ibv_qp_init_attr check_init_attr;
    if (ibv_query_qp(qp, &check_attr, IBV_QP_STATE | IBV_QP_SQ_PSN | IBV_QP_RQ_PSN, 
                     &check_init_attr) == 0) {
        printf("\n✓ Final QP State Verification:\n");
        printf("  QP State: %d (RTS=%d)\n", check_attr.qp_state, IBV_QPS_RTS);
        printf("  SQ PSN: 0x%06x\n", check_attr.sq_psn);
        printf("  RQ PSN: 0x%06x\n", check_attr.rq_psn);
    }

    printf("\n✅ SUCCESS: Pure IB verbs flow works with custom PSN!\n");
    
cleanup:
    ibv_destroy_qp(qp);
    ibv_destroy_cq(cq);
    ibv_dealloc_pd(pd);
    ibv_close_device(ctx);
    
    return ret;
}