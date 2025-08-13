#include "tls_utils.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <fcntl.h>

// macOS compatibility for htobe64/be64toh
#ifdef __APPLE__
#include <libkern/OSByteOrder.h>
#define htobe64(x) OSSwapHostToBigInt64(x)
#define be64toh(x) OSSwapBigToHostInt64(x)
#endif

int init_openssl(void) {
    SSL_load_error_strings();
    OpenSSL_add_ssl_algorithms();
    return 0;
}

void cleanup_openssl(void) {
    EVP_cleanup();
}

void print_ssl_error(const char *msg) {
    unsigned long err = ERR_get_error();
    char err_buf[256];
    ERR_error_string_n(err, err_buf, sizeof(err_buf));
    fprintf(stderr, "%s: %s\n", msg, err_buf);
}

SSL_CTX* create_server_context(void) {
    const SSL_METHOD *method;
    SSL_CTX *ctx;

    method = TLS_server_method();
    ctx = SSL_CTX_new(method);
    if (!ctx) {
        print_ssl_error("Unable to create SSL context");
        return NULL;
    }

    // Set minimum TLS version to 1.2
    SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION);
    
    // Set strong cipher suites
    SSL_CTX_set_cipher_list(ctx, "ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-GCM-SHA256");
    
    return ctx;
}

SSL_CTX* create_client_context(void) {
    const SSL_METHOD *method;
    SSL_CTX *ctx;

    method = TLS_client_method();
    ctx = SSL_CTX_new(method);
    if (!ctx) {
        print_ssl_error("Unable to create SSL context");
        return NULL;
    }

    // Set minimum TLS version to 1.2
    SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION);
    
    // For development, allow self-signed certificates
    SSL_CTX_set_verify(ctx, SSL_VERIFY_NONE, NULL);
    
    return ctx;
}

int configure_server_context(SSL_CTX *ctx, const char *cert_file, const char *key_file) {
    // Load certificate
    if (SSL_CTX_use_certificate_file(ctx, cert_file, SSL_FILETYPE_PEM) <= 0) {
        print_ssl_error("Failed to load certificate");
        return -1;
    }

    // Load private key
    if (SSL_CTX_use_PrivateKey_file(ctx, key_file, SSL_FILETYPE_PEM) <= 0) {
        print_ssl_error("Failed to load private key");
        return -1;
    }

    // Verify private key
    if (!SSL_CTX_check_private_key(ctx)) {
        fprintf(stderr, "Private key does not match certificate\n");
        return -1;
    }

    return 0;
}

int create_tls_listener(int port) {
    int sock;
    struct sockaddr_in addr;
    int opt = 1;

    sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) {
        perror("socket");
        return -1;
    }

    // Allow socket reuse
    if (setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt)) < 0) {
        perror("setsockopt");
        close(sock);
        return -1;
    }

    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = INADDR_ANY;

    if (bind(sock, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        perror("bind");
        close(sock);
        return -1;
    }

    if (listen(sock, 10) < 0) {
        perror("listen");
        close(sock);
        return -1;
    }

    printf("TLS server listening on port %d\n", port);
    return sock;
}

struct tls_connection* accept_tls_connection(int listen_sock, SSL_CTX *ctx) {
    struct tls_connection *conn;
    struct sockaddr_in addr;
    socklen_t len = sizeof(addr);
    
    conn = calloc(1, sizeof(*conn));
    if (!conn) {
        return NULL;
    }

    conn->socket = accept(listen_sock, (struct sockaddr*)&addr, &len);
    if (conn->socket < 0) {
        perror("accept");
        free(conn);
        return NULL;
    }

    conn->ssl = SSL_new(ctx);
    if (!conn->ssl) {
        print_ssl_error("SSL_new failed");
        close(conn->socket);
        free(conn);
        return NULL;
    }

    SSL_set_fd(conn->ssl, conn->socket);

    if (SSL_accept(conn->ssl) <= 0) {
        print_ssl_error("SSL_accept failed");
        SSL_free(conn->ssl);
        close(conn->socket);
        free(conn);
        return NULL;
    }

    printf("TLS connection accepted from %s:%d\n", 
           inet_ntoa(addr.sin_addr), ntohs(addr.sin_port));
    
    return conn;
}

struct tls_connection* connect_tls_server(const char *hostname, int port) {
    struct tls_connection *conn;
    struct sockaddr_in addr;
    struct hostent *host;
    SSL_CTX *ctx;

    conn = calloc(1, sizeof(*conn));
    if (!conn) {
        return NULL;
    }

    // Create context
    ctx = create_client_context();
    if (!ctx) {
        free(conn);
        return NULL;
    }
    conn->ctx = ctx;

    // Create socket
    conn->socket = socket(AF_INET, SOCK_STREAM, 0);
    if (conn->socket < 0) {
        perror("socket");
        SSL_CTX_free(ctx);
        free(conn);
        return NULL;
    }

    // Resolve hostname
    host = gethostbyname(hostname);
    if (!host) {
        fprintf(stderr, "Failed to resolve hostname: %s\n", hostname);
        close(conn->socket);
        SSL_CTX_free(ctx);
        free(conn);
        return NULL;
    }

    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    memcpy(&addr.sin_addr.s_addr, host->h_addr, host->h_length);

    // Connect
    if (connect(conn->socket, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        perror("connect");
        close(conn->socket);
        SSL_CTX_free(ctx);
        free(conn);
        return NULL;
    }

    // Create SSL connection
    conn->ssl = SSL_new(ctx);
    if (!conn->ssl) {
        print_ssl_error("SSL_new failed");
        close(conn->socket);
        SSL_CTX_free(ctx);
        free(conn);
        return NULL;
    }

    SSL_set_fd(conn->ssl, conn->socket);

    if (SSL_connect(conn->ssl) <= 0) {
        print_ssl_error("SSL_connect failed");
        SSL_free(conn->ssl);
        close(conn->socket);
        SSL_CTX_free(ctx);
        free(conn);
        return NULL;
    }

    printf("TLS connection established to %s:%d\n", hostname, port);
    return conn;
}

uint32_t generate_secure_psn(void) {
    uint32_t psn;
    
    // Use OpenSSL's secure random generator
    if (RAND_bytes((unsigned char*)&psn, sizeof(psn)) != 1) {
        // Fallback to /dev/urandom
        int fd = open("/dev/urandom", O_RDONLY);
        if (fd >= 0) {
            read(fd, &psn, sizeof(psn));
            close(fd);
        } else {
            // Last resort - use time-based seed
            srand(time(NULL) ^ getpid());
            psn = rand();
        }
    }
    
    // Ensure PSN is not zero and within valid range
    psn = (psn & 0x00FFFFFF) | 0x00000001;
    
    return psn;
}

int exchange_psn_server(struct tls_connection *conn, uint32_t *local_psn, uint32_t *remote_psn) {
    struct psn_exchange exchange;
    int ret;

    // Generate server PSN
    *local_psn = generate_secure_psn();
    exchange.server_psn = htonl(*local_psn);

    // Receive client PSN
    ret = SSL_read(conn->ssl, &exchange.client_psn, sizeof(exchange.client_psn));
    if (ret != sizeof(exchange.client_psn)) {
        print_ssl_error("Failed to receive client PSN");
        return -1;
    }
    *remote_psn = ntohl(exchange.client_psn);

    // Send server PSN
    ret = SSL_write(conn->ssl, &exchange.server_psn, sizeof(exchange.server_psn));
    if (ret != sizeof(exchange.server_psn)) {
        print_ssl_error("Failed to send server PSN");
        return -1;
    }

    printf("PSN Exchange - Server PSN: 0x%06x, Client PSN: 0x%06x\n", 
           *local_psn, *remote_psn);

    return 0;
}

int exchange_psn_client(struct tls_connection *conn, uint32_t *local_psn, uint32_t *remote_psn) {
    struct psn_exchange exchange;
    int ret;

    // Generate client PSN
    *local_psn = generate_secure_psn();
    exchange.client_psn = htonl(*local_psn);

    // Send client PSN
    ret = SSL_write(conn->ssl, &exchange.client_psn, sizeof(exchange.client_psn));
    if (ret != sizeof(exchange.client_psn)) {
        print_ssl_error("Failed to send client PSN");
        return -1;
    }

    // Receive server PSN
    ret = SSL_read(conn->ssl, &exchange.server_psn, sizeof(exchange.server_psn));
    if (ret != sizeof(exchange.server_psn)) {
        print_ssl_error("Failed to receive server PSN");
        return -1;
    }
    *remote_psn = ntohl(exchange.server_psn);

    printf("PSN Exchange - Client PSN: 0x%06x, Server PSN: 0x%06x\n", 
           *local_psn, *remote_psn);

    return 0;
}

int send_rdma_params(struct tls_connection *conn, struct rdma_conn_params *params) {
    int ret;
    
    // Convert to network byte order
    struct rdma_conn_params net_params;
    net_params.qp_num = htonl(params->qp_num);
    net_params.lid = htons(params->lid);
    memcpy(net_params.gid, params->gid, 16);
    net_params.psn = htonl(params->psn);
    net_params.rkey = htonl(params->rkey);
    net_params.remote_addr = htobe64(params->remote_addr);
    
    ret = SSL_write(conn->ssl, &net_params, sizeof(net_params));
    if (ret != sizeof(net_params)) {
        print_ssl_error("Failed to send RDMA parameters");
        return -1;
    }
    
    return 0;
}

int receive_rdma_params(struct tls_connection *conn, struct rdma_conn_params *params) {
    int ret;
    struct rdma_conn_params net_params;
    
    ret = SSL_read(conn->ssl, &net_params, sizeof(net_params));
    if (ret != sizeof(net_params)) {
        print_ssl_error("Failed to receive RDMA parameters");
        return -1;
    }
    
    // Convert from network byte order
    params->qp_num = ntohl(net_params.qp_num);
    params->lid = ntohs(net_params.lid);
    memcpy(params->gid, net_params.gid, 16);
    params->psn = ntohl(net_params.psn);
    params->rkey = ntohl(net_params.rkey);
    params->remote_addr = be64toh(net_params.remote_addr);
    
    return 0;
}

void close_tls_connection(struct tls_connection *conn) {
    if (conn) {
        if (conn->ssl) {
            SSL_shutdown(conn->ssl);
            SSL_free(conn->ssl);
        }
        if (conn->socket >= 0) {
            close(conn->socket);
        }
        if (conn->ctx) {
            SSL_CTX_free(conn->ctx);
        }
        free(conn);
    }
}