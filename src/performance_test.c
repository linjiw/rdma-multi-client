/**
 * RDMA Performance Testing Framework
 * Tests scalability from 10 to 10,000+ clients
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <time.h>
#include <sys/time.h>
#include <sys/resource.h>
#include <signal.h>
#include <errno.h>
#include <getopt.h>
#include <fcntl.h>
#include "rdma_compat.h"
#include "tls_utils.h"

#define DEFAULT_SERVER_IP "127.0.0.1"
#define DEFAULT_MESSAGE_SIZE 1024
#define DEFAULT_MESSAGES_PER_CLIENT 100
#define DEFAULT_THINK_TIME_MS 10

// Performance metrics
struct perf_metrics {
    // Connection metrics
    double min_connect_time;
    double max_connect_time;
    double avg_connect_time;
    double total_connect_time;
    
    // Message metrics
    double min_msg_latency;
    double max_msg_latency;
    double avg_msg_latency;
    double total_msg_time;
    uint64_t total_messages;
    uint64_t total_bytes;
    
    // Failure metrics
    int connection_failures;
    int message_failures;
    int timeout_count;
    
    // Resource metrics
    double peak_cpu_usage;
    double peak_memory_mb;
    int peak_threads;
    int peak_fds;
};

// Test configuration
struct test_config {
    char *server_ip;
    int num_clients;
    int message_size;
    int messages_per_client;
    int think_time_ms;
    int connection_delay_ms;
    int verbose;
    int use_threading;  // 1 for threads, 0 for processes
};

// Client context
struct client_context {
    int client_id;
    struct test_config *config;
    struct perf_metrics *metrics;
    pthread_mutex_t *metrics_lock;
    
    // Timing
    struct timeval connect_start;
    struct timeval connect_end;
    struct timeval test_start;
    struct timeval test_end;
    
    // Status
    int connected;
    int messages_sent;
    int errors;
};

// Global test state
static volatile int g_running = 1;
static struct perf_metrics g_metrics = {0};
static pthread_mutex_t g_metrics_lock = PTHREAD_MUTEX_INITIALIZER;

// Helper: Get current time in microseconds
static uint64_t get_time_us() {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec * 1000000ULL + tv.tv_usec;
}

// Helper: Calculate time difference in milliseconds
static double time_diff_ms(struct timeval *start, struct timeval *end) {
    return (end->tv_sec - start->tv_sec) * 1000.0 + 
           (end->tv_usec - start->tv_usec) / 1000.0;
}

// Get system resource usage
static void get_resource_usage(struct perf_metrics *metrics) {
    struct rusage usage;
    if (getrusage(RUSAGE_SELF, &usage) == 0) {
        double memory_mb = usage.ru_maxrss / 1024.0;  // Convert KB to MB
        if (memory_mb > metrics->peak_memory_mb) {
            metrics->peak_memory_mb = memory_mb;
        }
    }
    
    // Count threads
    FILE *fp = fopen("/proc/self/status", "r");
    if (fp) {
        char line[256];
        while (fgets(line, sizeof(line), fp)) {
            if (strncmp(line, "Threads:", 8) == 0) {
                int threads;
                sscanf(line, "Threads: %d", &threads);
                if (threads > metrics->peak_threads) {
                    metrics->peak_threads = threads;
                }
                break;
            }
        }
        fclose(fp);
    }
    
    // Count open file descriptors
    int fd_count = 0;
    for (int fd = 0; fd < 65536; fd++) {
        if (fcntl(fd, F_GETFD) != -1) {
            fd_count++;
        }
    }
    if (fd_count > metrics->peak_fds) {
        metrics->peak_fds = fd_count;
    }
}

// Simulate client work
static void* client_worker(void *arg) {
    struct client_context *ctx = (struct client_context *)arg;
    struct test_config *config = ctx->config;
    char *send_buffer = NULL;
    char *recv_buffer = NULL;
    
    // Allocate buffers
    send_buffer = malloc(config->message_size);
    recv_buffer = malloc(config->message_size);
    if (!send_buffer || !recv_buffer) {
        ctx->errors++;
        goto cleanup;
    }
    
    // Prepare message
    memset(send_buffer, 'A' + (ctx->client_id % 26), config->message_size);
    
    // Add connection delay to prevent thundering herd
    if (config->connection_delay_ms > 0) {
        usleep((ctx->client_id % 10) * config->connection_delay_ms * 1000);
    }
    
    // Record connection start time
    gettimeofday(&ctx->connect_start, NULL);
    
    // TODO: Actual RDMA connection code here
    // For now, simulate with sleep
    usleep(10000 + (rand() % 10000));  // 10-20ms connection time
    
    // Record connection end time
    gettimeofday(&ctx->connect_end, NULL);
    ctx->connected = 1;
    
    // Update connection metrics
    double connect_time = time_diff_ms(&ctx->connect_start, &ctx->connect_end);
    pthread_mutex_lock(ctx->metrics_lock);
    ctx->metrics->total_connect_time += connect_time;
    if (connect_time < ctx->metrics->min_connect_time || ctx->metrics->min_connect_time == 0) {
        ctx->metrics->min_connect_time = connect_time;
    }
    if (connect_time > ctx->metrics->max_connect_time) {
        ctx->metrics->max_connect_time = connect_time;
    }
    pthread_mutex_unlock(ctx->metrics_lock);
    
    // Send messages
    gettimeofday(&ctx->test_start, NULL);
    
    for (int i = 0; i < config->messages_per_client && g_running; i++) {
        uint64_t msg_start = get_time_us();
        
        // TODO: Actual RDMA send/recv
        // For now, simulate
        usleep(100 + (rand() % 200));  // 0.1-0.3ms per message
        
        uint64_t msg_end = get_time_us();
        double latency = (msg_end - msg_start) / 1000.0;  // Convert to ms
        
        // Update message metrics
        pthread_mutex_lock(ctx->metrics_lock);
        ctx->metrics->total_messages++;
        ctx->metrics->total_bytes += config->message_size;
        ctx->metrics->total_msg_time += latency;
        if (latency < ctx->metrics->min_msg_latency || ctx->metrics->min_msg_latency == 0) {
            ctx->metrics->min_msg_latency = latency;
        }
        if (latency > ctx->metrics->max_msg_latency) {
            ctx->metrics->max_msg_latency = latency;
        }
        pthread_mutex_unlock(ctx->metrics_lock);
        
        ctx->messages_sent++;
        
        // Think time between messages
        if (config->think_time_ms > 0) {
            usleep(config->think_time_ms * 1000);
        }
    }
    
    gettimeofday(&ctx->test_end, NULL);
    
    if (config->verbose) {
        printf("Client %d: Sent %d messages\n", ctx->client_id, ctx->messages_sent);
    }
    
cleanup:
    free(send_buffer);
    free(recv_buffer);
    return NULL;
}

// Run performance test
static int run_performance_test(struct test_config *config) {
    pthread_t *threads = NULL;
    struct client_context *clients = NULL;
    int ret = 0;
    
    printf("\n=== Starting Performance Test ===\n");
    printf("Clients: %d\n", config->num_clients);
    printf("Message Size: %d bytes\n", config->message_size);
    printf("Messages per Client: %d\n", config->messages_per_client);
    printf("Total Messages: %d\n", config->num_clients * config->messages_per_client);
    printf("================================\n\n");
    
    // Allocate resources
    threads = calloc(config->num_clients, sizeof(pthread_t));
    clients = calloc(config->num_clients, sizeof(struct client_context));
    if (!threads || !clients) {
        fprintf(stderr, "Failed to allocate memory for %d clients\n", config->num_clients);
        ret = -1;
        goto cleanup;
    }
    
    // Initialize metrics
    memset(&g_metrics, 0, sizeof(g_metrics));
    
    // Record start time
    struct timeval test_start, test_end;
    gettimeofday(&test_start, NULL);
    
    // Launch clients
    printf("Launching %d clients...\n", config->num_clients);
    for (int i = 0; i < config->num_clients; i++) {
        clients[i].client_id = i;
        clients[i].config = config;
        clients[i].metrics = &g_metrics;
        clients[i].metrics_lock = &g_metrics_lock;
        
        if (pthread_create(&threads[i], NULL, client_worker, &clients[i]) != 0) {
            fprintf(stderr, "Failed to create thread for client %d\n", i);
            g_metrics.connection_failures++;
        }
        
        // Periodic resource check
        if (i % 100 == 0) {
            get_resource_usage(&g_metrics);
            if (config->verbose) {
                printf("Launched %d clients...\n", i);
            }
        }
    }
    
    // Wait for all clients to complete
    printf("Waiting for clients to complete...\n");
    for (int i = 0; i < config->num_clients; i++) {
        if (threads[i]) {
            pthread_join(threads[i], NULL);
        }
    }
    
    // Record end time
    gettimeofday(&test_end, NULL);
    double total_time = time_diff_ms(&test_start, &test_end) / 1000.0;  // Convert to seconds
    
    // Final resource check
    get_resource_usage(&g_metrics);
    
    // Calculate averages
    if (g_metrics.total_messages > 0) {
        g_metrics.avg_msg_latency = g_metrics.total_msg_time / g_metrics.total_messages;
    }
    int successful_clients = config->num_clients - g_metrics.connection_failures;
    if (successful_clients > 0) {
        g_metrics.avg_connect_time = g_metrics.total_connect_time / successful_clients;
    }
    
    // Print results
    printf("\n=== Performance Test Results ===\n");
    printf("Test Duration: %.2f seconds\n", total_time);
    printf("\nConnection Metrics:\n");
    printf("  Successful: %d/%d (%.1f%%)\n", 
           successful_clients, config->num_clients,
           (successful_clients * 100.0) / config->num_clients);
    printf("  Min Connect Time: %.2f ms\n", g_metrics.min_connect_time);
    printf("  Max Connect Time: %.2f ms\n", g_metrics.max_connect_time);
    printf("  Avg Connect Time: %.2f ms\n", g_metrics.avg_connect_time);
    
    printf("\nMessage Metrics:\n");
    printf("  Total Messages: %lu\n", g_metrics.total_messages);
    printf("  Total Data: %.2f MB\n", g_metrics.total_bytes / (1024.0 * 1024.0));
    printf("  Throughput: %.2f msg/sec\n", g_metrics.total_messages / total_time);
    printf("  Bandwidth: %.2f MB/sec\n", 
           (g_metrics.total_bytes / (1024.0 * 1024.0)) / total_time);
    printf("  Min Latency: %.2f ms\n", g_metrics.min_msg_latency);
    printf("  Max Latency: %.2f ms\n", g_metrics.max_msg_latency);
    printf("  Avg Latency: %.2f ms\n", g_metrics.avg_msg_latency);
    
    printf("\nResource Usage:\n");
    printf("  Peak Memory: %.2f MB\n", g_metrics.peak_memory_mb);
    printf("  Peak Threads: %d\n", g_metrics.peak_threads);
    printf("  Peak FDs: %d\n", g_metrics.peak_fds);
    
    printf("================================\n");
    
cleanup:
    free(threads);
    free(clients);
    return ret;
}

// Signal handler
static void signal_handler(int sig) {
    printf("\nReceived signal %d, stopping test...\n", sig);
    g_running = 0;
}

// Print usage
static void print_usage(const char *prog) {
    printf("Usage: %s [options]\n", prog);
    printf("Options:\n");
    printf("  -c, --clients NUM       Number of clients (default: 10)\n");
    printf("  -s, --server IP         Server IP address (default: 127.0.0.1)\n");
    printf("  -m, --message-size SIZE Message size in bytes (default: 1024)\n");
    printf("  -n, --num-messages NUM  Messages per client (default: 100)\n");
    printf("  -t, --think-time MS     Think time between messages (default: 10)\n");
    printf("  -d, --delay MS          Connection delay between clients (default: 0)\n");
    printf("  -v, --verbose           Verbose output\n");
    printf("  -h, --help              Show this help\n");
    printf("\nExamples:\n");
    printf("  %s -c 100                    # Test with 100 clients\n", prog);
    printf("  %s -c 1000 -m 4096           # 1000 clients, 4KB messages\n", prog);
    printf("  %s -c 10000 -d 10 -t 100     # 10k clients with delays\n", prog);
}

int main(int argc, char *argv[]) {
    struct test_config config = {
        .server_ip = DEFAULT_SERVER_IP,
        .num_clients = 10,
        .message_size = DEFAULT_MESSAGE_SIZE,
        .messages_per_client = DEFAULT_MESSAGES_PER_CLIENT,
        .think_time_ms = DEFAULT_THINK_TIME_MS,
        .connection_delay_ms = 0,
        .verbose = 0,
        .use_threading = 1
    };
    
    // Parse command line
    static struct option long_options[] = {
        {"clients", required_argument, 0, 'c'},
        {"server", required_argument, 0, 's'},
        {"message-size", required_argument, 0, 'm'},
        {"num-messages", required_argument, 0, 'n'},
        {"think-time", required_argument, 0, 't'},
        {"delay", required_argument, 0, 'd'},
        {"verbose", no_argument, 0, 'v'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };
    
    int opt;
    while ((opt = getopt_long(argc, argv, "c:s:m:n:t:d:vh", long_options, NULL)) != -1) {
        switch (opt) {
            case 'c':
                config.num_clients = atoi(optarg);
                break;
            case 's':
                config.server_ip = optarg;
                break;
            case 'm':
                config.message_size = atoi(optarg);
                break;
            case 'n':
                config.messages_per_client = atoi(optarg);
                break;
            case 't':
                config.think_time_ms = atoi(optarg);
                break;
            case 'd':
                config.connection_delay_ms = atoi(optarg);
                break;
            case 'v':
                config.verbose = 1;
                break;
            case 'h':
                print_usage(argv[0]);
                return 0;
            default:
                print_usage(argv[0]);
                return 1;
        }
    }
    
    // Validate configuration
    if (config.num_clients <= 0 || config.num_clients > 100000) {
        fprintf(stderr, "Invalid number of clients: %d (must be 1-100000)\n", 
                config.num_clients);
        return 1;
    }
    
    // Set up signal handlers
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);
    
    // Adjust system limits if needed
    if (config.num_clients > 1000) {
        struct rlimit rlim;
        
        // Increase file descriptor limit
        rlim.rlim_cur = config.num_clients * 10;
        rlim.rlim_max = config.num_clients * 10;
        if (setrlimit(RLIMIT_NOFILE, &rlim) < 0) {
            fprintf(stderr, "Warning: Could not increase file descriptor limit\n");
        }
        
        // Increase thread limit
        rlim.rlim_cur = config.num_clients + 100;
        rlim.rlim_max = config.num_clients + 100;
        if (setrlimit(RLIMIT_NPROC, &rlim) < 0) {
            fprintf(stderr, "Warning: Could not increase process/thread limit\n");
        }
    }
    
    // Run the test
    return run_performance_test(&config);
}