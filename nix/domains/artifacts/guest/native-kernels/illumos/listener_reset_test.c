/* SPDX-License-Identifier: BSD-2-Clause */
/* This harness executes extracted patched sockfs functions with pthread-backed
 * locks and condition variables. It is not a native-kernel acceptance test. */
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

typedef bool boolean_t;
typedef unsigned int sock_connid_t;
typedef void *sock_upper_handle_t;
typedef struct {
  pthread_mutex_t native;
  unsigned int bit;
} kmutex_t;
typedef pthread_cond_t kcondvar_t;
struct sonode;
typedef struct {
  struct sonode *head;
} list_t;
struct sonode {
  kmutex_t so_lock, so_acceptq_lock;
  kcondvar_t so_acceptq_cv;
  list_t so_acceptq_list;
  struct sonode *so_listener;
  unsigned int so_acceptq_len, so_state, so_mode;
  sock_connid_t so_proto_connid;
  int so_error;
};
#include "listener_reset_flags.inc"
#define ASSERT assert
static _Thread_local unsigned int held;
static atomic_uint sleepers;
static void mutex_enter(kmutex_t *lock) {
  assert((held & lock->bit) == 0);
  assert(pthread_mutex_lock(&lock->native) == 0);
  held |= lock->bit;
}
static void mutex_exit(kmutex_t *lock) {
  assert((held & lock->bit) != 0);
  held &= ~lock->bit;
  assert(pthread_mutex_unlock(&lock->native) == 0);
}
#define MUTEX_HELD(lock) ((held & (lock)->bit) != 0)
static void cv_broadcast(kcondvar_t *condition) {
  assert(pthread_cond_broadcast(condition) == 0);
}
static int cv_wait_sig_swap(kcondvar_t *condition, kmutex_t *lock) {
  struct timespec deadline;
  assert(timespec_get(&deadline, TIME_UTC) == TIME_UTC);
  deadline.tv_sec += 10;
  held &= ~lock->bit;
  atomic_fetch_add(&sleepers, 1);
  assert(pthread_cond_timedwait(condition, &lock->native, &deadline) == 0);
  atomic_fetch_sub(&sleepers, 1);
  held |= lock->bit;
  return 1;
}
static struct sonode *list_remove_head(list_t *list) {
  struct sonode *node = list->head;
  list->head = NULL;
  return node;
}
static void soisdisconnected(struct sonode *node, int error) {
  assert(MUTEX_HELD(&node->so_lock));
  node->so_state &= ~SS_ISCONNECTED;
  node->so_error = error;
}
static void so_notify_disconnected(struct sonode *node, boolean_t failed,
                                   int error) {
  (void)failed;
  (void)error;
  mutex_exit(&node->so_lock);
}

#include "listener_reset_functions.inc"
struct waiter {
  struct sonode *listener;
  struct sonode *child;
  int error;
};
static void *accept_thread(void *argument) {
  struct waiter *waiter = argument;
  mutex_enter(&waiter->listener->so_acceptq_lock);
  waiter->error =
      so_acceptq_dequeue_locked(waiter->listener, false, &waiter->child);
  mutex_exit(&waiter->listener->so_acceptq_lock);
  return NULL;
}
static void initialize(struct sonode *node) {
  memset(node, 0, sizeof(*node));
  node->so_lock.bit = 1;
  node->so_acceptq_lock.bit = 2;
  assert(pthread_mutex_init(&node->so_lock.native, NULL) == 0);
  assert(pthread_mutex_init(&node->so_acceptq_lock.native, NULL) == 0);
  assert(pthread_cond_init(&node->so_acceptq_cv, NULL) == 0);
  node->so_mode = SM_LISTENERR;
  node->so_state = SS_ACCEPTCONN;
}
static void destroy(struct sonode *node) {
  assert(pthread_cond_destroy(&node->so_acceptq_cv) == 0);
  assert(pthread_mutex_destroy(&node->so_acceptq_lock.native) == 0);
  assert(pthread_mutex_destroy(&node->so_lock.native) == 0);
}
static void wait_for_acceptors(unsigned int count) {
  struct timespec start, current;
  assert(timespec_get(&start, TIME_UTC) == TIME_UTC);
  while (atomic_load(&sleepers) != count) {
    assert(timespec_get(&current, TIME_UTC) == TIME_UTC);
    assert(current.tv_sec - start.tv_sec < 10);
    sched_yield();
  }
}
/**
 * @cc [owner:ghuntley,label:verification;recovery] native-listener-reset-regressions
 * Actual patched dequeue/disconnect functions
 * MUST wake all blocked acceptors, refuse queued children after reset, preserve
 * the fence after SO_ERROR reads, and retain ordinary protocols' opt-out
 * behavior. Sanitizers check this harness only; native socket/interrupt
 * lifetime still requires guest machine evidence.
 */
int main(void) {
  for (unsigned int round = 0; round < 64; round++) {
    struct sonode listener;
    initialize(&listener);
    pthread_t threads[4];
    struct waiter waiters[4];
    for (unsigned int n = 0; n < 4; n++) {
      waiters[n] = (struct waiter){.listener = &listener};
      assert(pthread_create(&threads[n], NULL, accept_thread, &waiters[n]) ==
             0);
    }
    wait_for_acceptors(4);
    assert(so_disconnected(&listener, 1, ECONNRESET) == 0);
    for (unsigned int n = 0; n < 4; n++) {
      assert(pthread_join(threads[n], NULL) == 0);
      assert(waiters[n].error == ECONNRESET && waiters[n].child == NULL);
    }
    struct sonode child = {0};
    listener.so_acceptq_list.head = &child;
    listener.so_acceptq_len = 1;
    listener.so_error = 0; /* SO_ERROR consumption cannot clear fence. */
    struct sonode *accepted = &child;
    mutex_enter(&listener.so_acceptq_lock);
    assert(so_acceptq_dequeue_locked(&listener, false, &accepted) ==
           ECONNRESET);
    assert(accepted == NULL && listener.so_acceptq_list.head == &child);
    assert(so_acceptq_dequeue_locked(&listener, true, &accepted) == ECONNRESET);
    mutex_exit(&listener.so_acceptq_lock);
    listener.so_acceptq_list.head = NULL;
    destroy(&listener);
  }
  struct sonode ordinary;
  initialize(&ordinary);
  ordinary.so_mode = 0;
  assert(so_disconnected(&ordinary, 1, ECONNRESET) == 0);
  assert((ordinary.so_state & SS_LISTENERR) == 0);
  struct sonode *accepted = NULL;
  mutex_enter(&ordinary.so_acceptq_lock);
  assert(so_acceptq_dequeue_locked(&ordinary, true, &accepted) == EWOULDBLOCK);
  struct sonode child = {.so_listener = &ordinary};
  ordinary.so_acceptq_list.head = &child;
  ordinary.so_acceptq_len = 1;
  assert(so_acceptq_dequeue_locked(&ordinary, false, &accepted) == 0);
  assert(accepted == &child && ordinary.so_acceptq_len == 0 &&
         child.so_listener == NULL);
  mutex_exit(&ordinary.so_acceptq_lock);
  destroy(&ordinary);
  puts("listener reset extraction: 256 blocked accepts, "
       "sticky/queued/nonblocking refusal, protocol opt-out passed");
  return 0;
}
