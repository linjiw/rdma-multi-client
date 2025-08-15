#ifndef DISCONNECT_PROTOCOL_H
#define DISCONNECT_PROTOCOL_H

#include <time.h>
#include <stdbool.h>

// Protocol messages
#define DISCONNECT_REQ "$$DISCONNECT_REQ$$"
#define DISCONNECT_ACK "$$DISCONNECT_ACK$$"
#define DISCONNECT_FIN "$$DISCONNECT_FIN$$"

// Timeouts (in seconds)
#define DISCONNECT_TIMEOUT_CLIENT 5  // Client waits 5s for ACK
#define DISCONNECT_TIMEOUT_SERVER 3  // Server waits 3s for FIN after ACK
#define DISCONNECT_RETRY_COUNT 1     // Number of retries

// Disconnection states
enum disconnect_state {
    DISC_STATE_NONE = 0,        // Normal operation
    DISC_STATE_REQ_SENT,        // Client sent DISCONNECT_REQ
    DISC_STATE_REQ_RECEIVED,    // Server received DISCONNECT_REQ
    DISC_STATE_ACK_SENT,        // Server sent DISCONNECT_ACK
    DISC_STATE_ACK_RECEIVED,    // Client received DISCONNECT_ACK
    DISC_STATE_FIN_SENT,        // Client sent DISCONNECT_FIN
    DISC_STATE_FIN_RECEIVED,    // Server received DISCONNECT_FIN
    DISC_STATE_COMPLETED        // Disconnection completed
};

// Disconnection context
struct disconnect_context {
    enum disconnect_state state;
    time_t timeout_start;
    int retry_count;
    bool graceful;  // True if graceful disconnect, false if forced
};

// Function prototypes
static inline void init_disconnect_context(struct disconnect_context *ctx) {
    ctx->state = DISC_STATE_NONE;
    ctx->timeout_start = 0;
    ctx->retry_count = 0;
    ctx->graceful = true;
}

static inline bool is_disconnect_message(const char *msg) {
    return (strncmp(msg, DISCONNECT_REQ, strlen(DISCONNECT_REQ)) == 0 ||
            strncmp(msg, DISCONNECT_ACK, strlen(DISCONNECT_ACK)) == 0 ||
            strncmp(msg, DISCONNECT_FIN, strlen(DISCONNECT_FIN)) == 0);
}

static inline bool check_disconnect_timeout(struct disconnect_context *ctx, int timeout_seconds) {
    if (ctx->timeout_start == 0) {
        return false;
    }
    time_t now = time(NULL);
    return (now - ctx->timeout_start) >= timeout_seconds;
}

static inline void start_disconnect_timer(struct disconnect_context *ctx) {
    ctx->timeout_start = time(NULL);
}

static inline const char* disconnect_state_str(enum disconnect_state state) {
    switch (state) {
        case DISC_STATE_NONE: return "NONE";
        case DISC_STATE_REQ_SENT: return "REQ_SENT";
        case DISC_STATE_REQ_RECEIVED: return "REQ_RECEIVED";
        case DISC_STATE_ACK_SENT: return "ACK_SENT";
        case DISC_STATE_ACK_RECEIVED: return "ACK_RECEIVED";
        case DISC_STATE_FIN_SENT: return "FIN_SENT";
        case DISC_STATE_FIN_RECEIVED: return "FIN_RECEIVED";
        case DISC_STATE_COMPLETED: return "COMPLETED";
        default: return "UNKNOWN";
    }
}

#endif // DISCONNECT_PROTOCOL_H