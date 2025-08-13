#ifndef TLS_UTILS_H
#define TLS_UTILS_H

#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/rand.h>
#include <stdint.h>

#define TLS_PORT 4433
#define CERT_FILE "server.crt"
#define KEY_FILE "server.key"

struct tls_connection {
    SSL_CTX *ctx;
    SSL *ssl;
    int socket;
};

struct psn_exchange {
    uint32_t client_psn;
    uint32_t server_psn;
};

struct rdma_conn_params {
    uint32_t qp_num;
    uint16_t lid;
    uint8_t gid[16];
    uint32_t psn;
    uint32_t rkey;
    uint64_t remote_addr;
};

// TLS initialization
int init_openssl(void);
void cleanup_openssl(void);

// Server functions
SSL_CTX* create_server_context(void);
int configure_server_context(SSL_CTX *ctx, const char *cert_file, const char *key_file);
int create_tls_listener(int port);
struct tls_connection* accept_tls_connection(int listen_sock, SSL_CTX *ctx);

// Client functions
SSL_CTX* create_client_context(void);
struct tls_connection* connect_tls_server(const char *hostname, int port);

// PSN exchange functions
uint32_t generate_secure_psn(void);
int exchange_psn_server(struct tls_connection *conn, uint32_t *local_psn, uint32_t *remote_psn);
int exchange_psn_client(struct tls_connection *conn, uint32_t *local_psn, uint32_t *remote_psn);

// RDMA parameter exchange
int send_rdma_params(struct tls_connection *conn, struct rdma_conn_params *params);
int receive_rdma_params(struct tls_connection *conn, struct rdma_conn_params *params);

// Utility functions
void print_ssl_error(const char *msg);
void close_tls_connection(struct tls_connection *conn);

#endif // TLS_UTILS_H