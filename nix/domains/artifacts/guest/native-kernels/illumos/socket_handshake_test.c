/* SPDX-License-Identifier: BSD-2-Clause */
/* The extracted socket downcall runs against pthread-backed synchronization.
 * This establishes host control-flow evidence, not native transport acceptance. */
#include "ov_vsock.h"
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

typedef bool boolean_t;
typedef unsigned int uint_t;
typedef pthread_mutex_t kmutex_t;
typedef pthread_cond_t kcondvar_t;
typedef void *sock_lower_handle_t;
typedef void *sock_upper_handle_t;
typedef struct sock_upcalls sock_upcalls_t;
typedef struct cred cred_t;
#define OV_ILLUMOS_WINDOW 65536U
#define B_TRUE true
#define B_FALSE false
#define VERIFY assert
static kmutex_t vs_lock = PTHREAD_MUTEX_INITIALIZER;
static atomic_uint sleeping;
static atomic_bool interrupted;

static void mutex_enter(kmutex_t *lock) {
  assert(pthread_mutex_lock(lock) == 0);
}
static void mutex_exit(kmutex_t *lock) {
  assert(pthread_mutex_unlock(lock) == 0);
}
static int cv_wait_sig(kcondvar_t *condition, kmutex_t *lock) {
  struct timespec deadline;
  assert(timespec_get(&deadline, TIME_UTC) == TIME_UTC);
  deadline.tv_sec += 10;
  atomic_fetch_add(&sleeping, 1);
  assert(pthread_cond_timedwait(condition, lock, &deadline) == 0);
  atomic_fetch_sub(&sleeping, 1);
  return !atomic_load(&interrupted);
}
static void cv_broadcast(kcondvar_t *condition) {
  assert(pthread_cond_broadcast(condition) == 0);
}

#include "socket_handshake_types.inc"
static struct vs_socket *vs_sockets;
static int vs_control(struct vs_socket *endpoint, uint16_t operation,
                      uint32_t flags) {
  (void)endpoint;
  (void)operation;
  (void)flags;
  assert(false); /* These cases close only a listener, not a connected child. */
  return EIO;
}
static void vs_put(struct vs_socket *endpoint) {
  assert(endpoint->refs > 0);
  endpoint->refs--;
}
#include "socket_handshake_function.inc"

struct attempt {
  struct vs_socket *listener;
  struct vs_socket *child;
  atomic_bool returned;
  int error;
};
static void *accept_thread(void *argument) {
  struct attempt *attempt = argument;
  attempt->error = vs_accept(attempt->listener, attempt->child, attempt, NULL);
  atomic_store(&attempt->returned, true);
  return NULL;
}
static void wait_for_accept(struct attempt *attempt) {
  struct timespec start, current;
  assert(timespec_get(&start, TIME_UTC) == TIME_UTC);
  while (atomic_load(&sleeping) == 0) {
    assert(!atomic_load(&attempt->returned));
    assert(timespec_get(&current, TIME_UTC) == TIME_UTC);
    assert(current.tv_sec - start.tv_sec < 10);
    sched_yield();
  }
}

/**
 * @cc [owner:ghuntley,label:verification;protocol] native-accept-response-order
 * Actual sd_accept MUST prevent an application from closing an accepted socket
 * before its pending RESPONSE has been submitted. Actual sd_close of a listener
 * MUST wake and refuse its waiting child without a manually injected child wake.
 * Reset and interrupted waits MUST refuse without publishing the upper handle.
 * These forced schedules MUST NOT establish native interrupt or DMA safety.
 */
int main(void) {
  for (unsigned int round = 0; round < 64; round++) {
    for (unsigned int outcome = 0; outcome < 4; outcome++) {
      struct vs_socket listener = {
          .listening = true, .local_port = 1024, .refs = 2};
      struct vs_socket child = {
          .handshake = true, .local_port = 1024, .refs = 1};
      listener.next = &child;
      vs_sockets = &listener;
      child.connection.phase = OV_VSOCK_ESTABLISHED;
      assert(pthread_cond_init(&listener.cv, NULL) == 0);
      assert(pthread_cond_init(&child.cv, NULL) == 0);
      atomic_store(&interrupted, false);
      struct attempt attempt = {.listener = &listener, .child = &child};
      atomic_init(&attempt.returned, false);
      pthread_t thread;
      assert(pthread_create(&thread, NULL, accept_thread, &attempt) == 0);
      wait_for_accept(&attempt);
      assert(!atomic_load(&attempt.returned) && child.upper == NULL);
      if (outcome == 2) {
        assert(vs_close(&listener, 0, NULL) == EINPROGRESS);
        assert(vs_sockets == &child && listener.refs == 1);
      } else {
        mutex_enter(&vs_lock);
        if (outcome == 0) {
          child.handshake = false; /* The RESPONSE has now been submitted. */
        } else if (outcome == 1) {
          child.error = ECONNRESET;
          child.connection.phase = OV_VSOCK_CLOSED;
        } else {
          atomic_store(&interrupted, true);
        }
        cv_broadcast(&child.cv);
        mutex_exit(&vs_lock);
      }
      assert(pthread_join(thread, NULL) == 0);
      assert(attempt.error == (outcome == 0 ? 0 : outcome == 3 ? EINTR : ECONNRESET));
      assert(child.upper == (outcome == 0 ? &attempt : NULL));
      assert(atomic_load(&sleeping) == 0);
      assert(pthread_cond_destroy(&child.cv) == 0);
      assert(pthread_cond_destroy(&listener.cv) == 0);
      vs_sockets = NULL;
    }
  }
  puts("socket accept handshake: response publication, reset, close and signal passed");
  return 0;
}
