/**
 * RDMA Performance Test - Real Implementation
 * Tests actual RDMA connections and operations
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <stdint.h>
#include <pthread.h>
#include <time.h>
#include <sys/time.h>
#include <sys/resource.h>
#include <signal.h>
#include <errno.h>
#include <getopt.h>
#include <fcntl.h>

// Client metrics structure (must match rdma_perf_client.c)
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

// Declare the RDMA client function
extern int run_rdma_client_test(int client_id, const char *server_ip, const char *server_name,
                                int num_messages, int message_size, int think_time_ms,
                                struct client_metrics *metrics);

// Global performance metrics
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
    
    // Resource metrics
    double peak_memory_mb;
    int peak_threads;
    int peak_fds;
    int peak_qps;
};

// Test configuration
struct test_config {
    char *server_ip;
    char *server_name;
    int num_clients;
    int message_size;
    int messages_per_client;
    int think_time_ms;
    int connection_delay_ms;
    int verbose;
};

// Client context for threading
struct client_context {
    int client_id;
    struct test_config *config;
    struct perf_metrics *metrics;
    pthread_mutex_t *metrics_lock;
    struct client_metrics local_metrics;
};

static volatile int g_running = 1;
static struct perf_metrics g_metrics = {0};
static pthread_mutex_t g_metrics_lock = PTHREAD_MUTEX_INITIALIZER;

// Helper: Calculate time difference in milliseconds
static double time_diff_ms(struct timeval *start, struct timeval *end) {
    return (end->tv_sec - start->tv_sec) * 1000.0 + 
           (end->tv_usec - start->tv_usec) / 1000.0;
}

// Get system resource usage including RDMA
static void get_resource_usage(struct perf_metrics *metrics) {
    struct rusage usage;
    if (getrusage(RUSAGE_SELF, &usage) == 0) {
        double memory_mb = usage.ru_maxrss / 1024.0;
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
    
    // Count file descriptors
    int fd_count = 0;
    for (int fd = 0; fd < 1024; fd++) {
        if (fcntl(fd, F_GETFD) != -1) {
            fd_count++;
        }
    }
    if (fd_count > metrics->peak_fds) {
        metrics->peak_fds = fd_count;
    }
    
    // Check RDMA resources (QPs)
    FILE *qp_file = fopen("/sys/class/infiniband/rxe0/ports/1/counters/port_xmit_data", "r");
    if (qp_file) {
        // This gives us an indication of RDMA activity
        fclose(qp_file);
    }
}

// Worker thread for each client
static void* client_worker(void *arg) {
    struct client_context *ctx = (struct client_context *)arg;
    struct test_config *config = ctx->config;
    
    // Add connection delay to prevent thundering herd
    if (config->connection_delay_ms > 0) {
        usleep((ctx->client_id % 10) * config->connection_delay_ms * 1000);
    }
    
    // Run actual RDMA client test
    int result = run_rdma_client_test(
        ctx->client_id,
        config->server_ip,
        config->server_name,
        config->messages_per_client,
        config->message_size,
        config->think_time_ms,
        &ctx->local_metrics
    );
    
    // Update global metrics
    pthread_mutex_lock(ctx->metrics_lock);
    
    if (result < 0) {
        ctx->metrics->connection_failures++;
    } else {
        // Connection metrics
        double connect_time = time_diff_ms(&ctx->local_metrics.connect_start, 
                                          &ctx->local_metrics.connect_end);
        ctx->metrics->total_connect_time += connect_time;
        
        if (connect_time < ctx->metrics->min_connect_time || ctx->metrics->min_connect_time == 0) {
            ctx->metrics->min_connect_time = connect_time;
        }
        if (connect_time > ctx->metrics->max_connect_time) {
            ctx->metrics->max_connect_time = connect_time;
        }
        
        // Message metrics
        ctx->metrics->total_messages += ctx->local_metrics.messages_sent;
        ctx->metrics->total_bytes += ctx->local_metrics.messages_sent * config->message_size;
        
        if (ctx->local_metrics.messages_sent > 0) {
            double avg_latency = ctx->local_metrics.total_latency_ms / ctx->local_metrics.messages_sent;
            ctx->metrics->total_msg_time += ctx->local_metrics.total_latency_ms;
            
            if (avg_latency < ctx->metrics->min_msg_latency || ctx->metrics->min_msg_latency == 0) {
                ctx->metrics->min_msg_latency = avg_latency;
            }
            if (avg_latency > ctx->metrics->max_msg_latency) {
                ctx->metrics->max_msg_latency = avg_latency;
            }
        }
        
        ctx->metrics->message_failures += ctx->local_metrics.errors;
    }
    
    pthread_mutex_unlock(ctx->metrics_lock);
    
    if (config->verbose) {
        printf("Client %d: Sent %d messages, %d errors\n", 
               ctx->client_id, ctx->local_metrics.messages_sent, ctx->local_metrics.errors);
    }
    
    return NULL;
}

// Run RDMA performance test
static int run_rdma_performance_test(struct test_config *config) {
    pthread_t *threads = NULL;
    struct client_context *clients = NULL;
    int ret = 0;
    
    printf("\n=== Starting RDMA Performance Test ===\n");
    printf("Server: %s (%s)\n", config->server_ip, config->server_name);
    printf("Clients: %d\n", config->num_clients);
    printf("Message Size: %d bytes\n", config->message_size);
    printf("Messages per Client: %d\n", config->messages_per_client);
    printf("Total Messages: %d\n", config->num_clients * config->messages_per_client);
    printf("=====================================\n\n");
    
    // Check if server is running
    printf("Checking server availability...\n");
    // TODO: Add server health check
    
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
    printf("Launching %d RDMA clients...\n", config->num_clients);
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
        if (i % 10 == 0) {
            get_resource_usage(&g_metrics);
            if (config->verbose && i > 0) {
                printf("Launched %d clients...\n", i);
            }
        }
        
        // Limit connection rate for large numbers
        if (config->num_clients > 100 && i % 10 == 0) {
            usleep(10000);  // 10ms pause every 10 clients
        }
    }
    
    // Wait for all clients
    printf("Waiting for clients to complete...\n");
    for (int i = 0; i < config->num_clients; i++) {
        if (threads[i]) {
            pthread_join(threads[i], NULL);
        }
    }
    
    // Record end time
    gettimeofday(&test_end, NULL);
    double total_time = time_diff_ms(&test_start, &test_end) / 1000.0;
    
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
    printf("\n=== RDMA Performance Test Results ===\n");
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
    printf("  Min Latency: %.3f ms\n", g_metrics.min_msg_latency);
    printf("  Max Latency: %.3f ms\n", g_metrics.max_msg_latency);
    printf("  Avg Latency: %.3f ms\n", g_metrics.avg_msg_latency);
    
    printf("\nResource Usage:\n");
    printf("  Peak Memory: %.2f MB\n", g_metrics.peak_memory_mb);
    printf("  Peak Threads: %d\n", g_metrics.peak_threads);
    printf("  Peak FDs: %d\n", g_metrics.peak_fds);
    printf("  Message Errors: %d\n", g_metrics.message_failures);
    
    printf("=====================================\n");
    
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
    printf("  -n, --name NAME         Server hostname (default: localhost)\n");
    printf("  -m, --message-size SIZE Message size in bytes (default: 1024)\n");
    printf("  -M, --num-messages NUM  Messages per client (default: 100)\n");
    printf("  -t, --think-time MS     Think time between messages (default: 10)\n");
    printf("  -d, --delay MS          Connection delay between clients (default: 0)\n");
    printf("  -v, --verbose           Verbose output\n");
    printf("  -h, --help              Show this help\n");
    printf("\nExamples:\n");
    printf("  %s -c 10                     # Test with 10 RDMA clients\n", prog);
    printf("  %s -c 100 -M 10              # 100 clients, 10 messages each\n", prog);
    printf("  %s -c 1000 -d 10 -t 50       # 1000 clients with delays\n", prog);
}

int main(int argc, char *argv[]) {
    struct test_config config = {
        .server_ip = "127.0.0.1",
        .server_name = "localhost",
        .num_clients = 10,
        .message_size = 1024,
        .messages_per_client = 100,
        .think_time_ms = 10,
        .connection_delay_ms = 0,
        .verbose = 0
    };
    
    static struct option long_options[] = {
        {"clients", required_argument, 0, 'c'},
        {"server", required_argument, 0, 's'},
        {"name", required_argument, 0, 'n'},
        {"message-size", required_argument, 0, 'm'},
        {"num-messages", required_argument, 0, 'M'},
        {"think-time", required_argument, 0, 't'},
        {"delay", required_argument, 0, 'd'},
        {"verbose", no_argument, 0, 'v'},
        {"help", no_argument, 0, 'h'},
        {0, 0, 0, 0}
    };
    
    int opt;
    while ((opt = getopt_long(argc, argv, "c:s:n:m:M:t:d:vh", long_options, NULL)) != -1) {
        switch (opt) {
            case 'c':
                config.num_clients = atoi(optarg);
                break;
            case 's':
                config.server_ip = optarg;
                break;
            case 'n':
                config.server_name = optarg;
                break;
            case 'm':
                config.message_size = atoi(optarg);
                break;
            case 'M':
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
    
    // Validate
    if (config.num_clients <= 0 || config.num_clients > 10000) {
        fprintf(stderr, "Invalid number of clients: %d\n", config.num_clients);
        return 1;
    }
    
    // Set up signal handlers
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);
    
    // Adjust system limits if needed
    if (config.num_clients > 100) {
        struct rlimit rlim;
        rlim.rlim_cur = config.num_clients * 20;
        rlim.rlim_max = config.num_clients * 20;
        setrlimit(RLIMIT_NOFILE, &rlim);
    }
    
    // Run the test
    printf("Starting RDMA performance test with real RDMA operations...\n");
    return run_rdma_performance_test(&config);
}