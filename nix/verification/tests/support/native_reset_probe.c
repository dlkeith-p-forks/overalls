/* Test-only native reset oracle; no guest service or production API. */
#include <sys/socket.h>
#include <sys/types.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#if defined(__FreeBSD__)
#define NATIVE_AF 45
#else
#define NATIVE_AF 40
#endif

struct native_address {
    uint8_t header[4];
    uint32_t port;
    uint32_t cid;
    uint8_t zero[4];
};

enum operation_kind { BLOCK_ACCEPT, BLOCK_READ, BLOCK_WRITE };

struct operation {
    enum operation_kind kind;
    int fd;
    pthread_t thread;
    atomic_bool entered;
    atomic_bool done;
    atomic_size_t written;
    ssize_t result;
    int error;
};

static void fail(const char *boundary) {
    (void)printf("{\"event\":\"native-reset-failed\",\"boundary\":\"%s\"}\n", boundary);
    exit(1);
}

static int new_socket(void) {
    return socket(NATIVE_AF, SOCK_STREAM, 0);
}

static int listener(uint32_t port) {
    int fd = new_socket();
    struct native_address address = { .port = port, .cid = 3 };
#if defined(__FreeBSD__)
    address.header[0] = sizeof(address);
    address.header[1] = NATIVE_AF;
#else
    address.header[0] = NATIVE_AF;
#endif
    if (fd < 0 || bind(fd, (const struct sockaddr *)&address, sizeof(address)) != 0 ||
        listen(fd, 1) != 0) {
        fail("listener");
    }
    return fd;
}

static int identity(int fd, char token[65]) {
    socklen_t size = 65;
    memset(token, 0, 65);
    return getsockopt(fd, NATIVE_AF, 1, token, &size);
}

static void *blocked(void *argument) {
    struct operation *operation = argument;
    char bytes[65536] = { 0 };
    atomic_store(&operation->entered, true);
    if (operation->kind == BLOCK_ACCEPT) {
        operation->result = accept(operation->fd, NULL, NULL);
    } else if (operation->kind == BLOCK_READ) {
        operation->result = recv(operation->fd, bytes, 1, 0);
    } else {
        do {
            operation->result = send(operation->fd, bytes, sizeof(bytes), 0);
            if (operation->result > 0) {
                atomic_fetch_add(&operation->written, (size_t)operation->result);
            }
        } while (operation->result > 0 && atomic_load(&operation->written) < 16777216);
    }
    operation->error = operation->result < 0 ? errno : 0;
    atomic_store(&operation->done, true);
    return NULL;
}

/* @cc [owner:ghuntley,label:verification] native-reset-live-socket-oracle
 * The isolated probe MUST establish live kernel identity before reset, retain
 * a socket with no peer, and require its identity option to fail ECONNRESET.
 * Pending read/write calls MUST wake with errors; host connection loss alone
 * MUST NOT satisfy the idle-socket condition. The original listener MUST accept
 * a fresh connection after reset, and fresh sockets MUST retain the build ID.
 */
int main(void) {
    int idle, read_listener, write_listener;
    char original[65], current[65];
    uint64_t memory_nonce;
    pid_t original_pid = getpid();
    int random_fd = open("/dev/urandom", O_RDONLY);
    if (random_fd < 0 || read(random_fd, &memory_nonce, sizeof(memory_nonce)) !=
        sizeof(memory_nonce) || close(random_fd) != 0) {
        fail("memory-nonce");
    }
    struct operation operations[3] = {
        { .kind = BLOCK_ACCEPT }, { .kind = BLOCK_READ }, { .kind = BLOCK_WRITE }
    };
    setbuf(stdout, NULL);
    (void)signal(SIGPIPE, SIG_IGN);
    (void)alarm(60);
    if (geteuid() != 0) {
        fail("root");
    }
    idle = new_socket();
    if (idle < 0 || identity(idle, original) != 0 || strlen(original) != 64) {
        fail("initial-identity");
    }
    for (size_t index = 0; index < 64; index++) {
        if (!((original[index] >= '0' && original[index] <= '9') ||
            (original[index] >= 'a' && original[index] <= 'f'))) {
            fail("identity-shape");
        }
    }
    operations[0].fd = listener(1101);
    read_listener = listener(1102);
    write_listener = listener(1103);
    (void)printf("{\"event\":\"native-reset-listeners-ready\",\"build_id\":\"%s\",\"memory_nonce\":\"%016llx\",\"pid\":%ld}\n", original, (unsigned long long)memory_nonce, (long)original_pid);
    operations[1].fd = accept(read_listener, NULL, NULL);
    operations[2].fd = accept(write_listener, NULL, NULL);
    if (operations[1].fd < 0 || operations[2].fd < 0) {
        fail("host-connections");
    }
    for (size_t index = 0; index < 3; index++) {
        if (pthread_create(&operations[index].thread, NULL, blocked, &operations[index]) != 0) {
            fail("thread-start");
        }
    }
    (void)sleep(1);
    for (size_t index = 0; index < 3; index++) {
        if (!atomic_load(&operations[index].entered) || atomic_load(&operations[index].done)) {
            fail("operation-not-pending");
        }
    }
    (void)printf("{\"event\":\"native-reset-armed\",\"accept_pending\":true,\"read_pending\":true,\"write_pending\":true}\n");
    bool reset = false;
    for (size_t attempt = 0; attempt < 300; attempt++) {
        if (identity(idle, current) != 0) {
            if (errno != ECONNRESET) {
                fail("idle-wrong-error");
            }
            reset = true;
            break;
        }
        if (strcmp(original, current) != 0) {
            fail("identity-mutated");
        }
        (void)usleep(100000);
    }
    if (!reset) {
        fail("idle-not-fenced");
    }
    for (size_t attempt = 0; attempt < 50; attempt++) {
        if (atomic_load(&operations[1].done) && atomic_load(&operations[2].done)) {
            break;
        }
        (void)usleep(100000);
    }
    for (size_t index = 1; index < 3; index++) {
        if (!atomic_load(&operations[index].done) || operations[index].result != -1 ||
            operations[index].error == 0) {
            fail("blocked-operation-not-refused");
        }
        if (pthread_join(operations[index].thread, NULL) != 0) {
            fail("thread-join");
        }
    }
    if (atomic_load(&operations[0].done)) {
        fail("listener-fenced-by-reset");
    }
    int fresh = new_socket();
    if (fresh < 0 || identity(fresh, current) != 0 || strcmp(original, current) != 0) {
        fail("fresh-socket-not-revalidated");
    }
    const char *fresh_state = "current-cid-revalidated";
    (void)printf("{\"event\":\"native-reset-reconnect-ready\",\"memory_nonce\":\"%016llx\",\"pid\":%ld}\n", (unsigned long long)memory_nonce, (long)getpid());
    if (pthread_join(operations[0].thread, NULL) != 0 ||
        operations[0].result < 0 || operations[0].error != 0) {
        fail("original-listener-not-reusable");
    }
    (void)close((int)operations[0].result);
    (void)printf("{\"event\":\"native-reset-verified\",\"idle_error\":%d,\"accept_error\":%d,\"read_error\":%d,\"write_error\":%d,\"written_before_refusal\":%zu,\"fresh_socket\":\"%s\",\"native_admission\":false}\n",
        ECONNRESET, operations[0].error, operations[1].error, operations[2].error,
        atomic_load(&operations[2].written), fresh_state);
    if (fresh >= 0) {
        (void)close(fresh);
    }
    (void)close(idle);
    (void)close(read_listener);
    (void)close(write_listener);
    for (size_t index = 0; index < 3; index++) {
        (void)close(operations[index].fd);
    }
    return 0;
}
