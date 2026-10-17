#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

struct reader_input {
  const char *source;
  atomic_int ready;
};

static struct reader_input input;

/** @cc [owner:ghuntley,label:verification] backup-thread-reader-fixture
 * Each worker MUST open the source before announcing readiness and keep it open
 * after the process leader exits. The fixture MUST retain its original group.
 */
static void *reader(void *argument) {
  struct reader_input *state = argument;
  int descriptor = open(state->source, O_RDONLY);
  if (descriptor < 0) {
    _exit(2);
  }
  atomic_fetch_add(&state->ready, 1);
  const struct timespec duration = {.tv_sec = 30, .tv_nsec = 0};
  nanosleep(&duration, NULL);
  close(descriptor);
  return NULL;
}

/** @cc [owner:ghuntley,label:verification] backup-thread-leader-exit
 * After all one-to-three readers open the source, the main thread MUST use
 * pthread_exit so the leader becomes a zombie while live workers remain.
 */
int main(int argc, char **argv) {
  if (argc != 3) {
    return 2;
  }
  char *end = NULL;
  errno = 0;
  long count = strtol(argv[1], &end, 10);
  if (errno != 0 || end == argv[1] || *end != '\0' || count < 1 || count > 3) {
    return 2;
  }
  input.source = argv[2];
  atomic_init(&input.ready, 0);
  for (long index = 0; index < count; ++index) {
    pthread_t thread;
    if (pthread_create(&thread, NULL, reader, &input) != 0) {
      return 2;
    }
  }
  while (atomic_load(&input.ready) != count) {
    const struct timespec interval = {.tv_sec = 0, .tv_nsec = 1000000};
    nanosleep(&interval, NULL);
  }
  pthread_exit(NULL);
}
