/* A single, append-only syscall per complete fallback JSONL record. */
#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

enum { MAX_RECORD = 4096 };

static int read_full(int fd, unsigned char *buffer, size_t length) {
  size_t offset = 0;
  while (offset < length) {
    ssize_t count = read(fd, buffer + offset, length - offset);
    if (count == 0) return 0;
    if (count < 0) {
      if (errno == EINTR) continue;
      return -1;
    }
    offset += (size_t)count;
  }
  return 1;
}

static int reply(unsigned char result) {
  const unsigned char frame[5] = {0, 0, 0, 1, result};
  return write(STDOUT_FILENO, frame, sizeof frame) == (ssize_t)sizeof frame ? 0 : -1;
}

struct json_cursor {
  const unsigned char *bytes;
  size_t length;
  size_t offset;
};

static void skip_space(struct json_cursor *cursor) {
  while (cursor->offset < cursor->length &&
         (cursor->bytes[cursor->offset] == ' ' || cursor->bytes[cursor->offset] == '\t'))
    cursor->offset++;
}

static int consume(struct json_cursor *cursor, unsigned char expected) {
  skip_space(cursor);
  if (cursor->offset >= cursor->length || cursor->bytes[cursor->offset] != expected) return 0;
  cursor->offset++;
  return 1;
}

static int hex_value(unsigned char byte) {
  if (byte >= '0' && byte <= '9') return byte - '0';
  if (byte >= 'a' && byte <= 'f') return byte - 'a' + 10;
  if (byte >= 'A' && byte <= 'F') return byte - 'A' + 10;
  return -1;
}

static int unicode_escape(struct json_cursor *cursor) {
  if (cursor->offset + 4 > cursor->length) return -1;
  int value = 0;
  for (int i = 0; i < 4; i++) {
    int digit = hex_value(cursor->bytes[cursor->offset++]);
    if (digit < 0) return -1;
    value = (value << 4) | digit;
  }
  return value;
}

static int utf8_scalar(struct json_cursor *cursor, unsigned char first) {
  size_t remaining = cursor->length - cursor->offset;
  const unsigned char *tail = cursor->bytes + cursor->offset;
  if (first >= 0xc2 && first <= 0xdf && remaining >= 1 &&
      tail[0] >= 0x80 && tail[0] <= 0xbf) {
    cursor->offset += 1;
    return 1;
  }
  if (remaining >= 2 && tail[1] >= 0x80 && tail[1] <= 0xbf) {
    int second_ok = (first == 0xe0 && tail[0] >= 0xa0 && tail[0] <= 0xbf) ||
                    (first >= 0xe1 && first <= 0xec && tail[0] >= 0x80 && tail[0] <= 0xbf) ||
                    (first == 0xed && tail[0] >= 0x80 && tail[0] <= 0x9f) ||
                    (first >= 0xee && first <= 0xef && tail[0] >= 0x80 && tail[0] <= 0xbf);
    if (second_ok) {
      cursor->offset += 2;
      return 1;
    }
  }
  if (remaining >= 3 && tail[1] >= 0x80 && tail[1] <= 0xbf &&
      tail[2] >= 0x80 && tail[2] <= 0xbf) {
    int second_ok = (first == 0xf0 && tail[0] >= 0x90 && tail[0] <= 0xbf) ||
                    (first >= 0xf1 && first <= 0xf3 && tail[0] >= 0x80 && tail[0] <= 0xbf) ||
                    (first == 0xf4 && tail[0] >= 0x80 && tail[0] <= 0x8f);
    if (second_ok) {
      cursor->offset += 3;
      return 1;
    }
  }
  return 0;
}

static int parse_string(struct json_cursor *cursor) {
  if (!consume(cursor, '"')) return 0;
  while (cursor->offset < cursor->length) {
    unsigned char byte = cursor->bytes[cursor->offset++];
    if (byte == '"') return 1;
    if (byte < 0x20) return 0;
    if (byte >= 0x80 && !utf8_scalar(cursor, byte)) return 0;
    if (byte != '\\') continue;
    if (cursor->offset >= cursor->length) return 0;
    byte = cursor->bytes[cursor->offset++];
    if (byte == 'u') {
      int code = unicode_escape(cursor);
      if (code < 0) return 0;
      if (code >= 0xdc00 && code <= 0xdfff) return 0;
      if (code >= 0xd800 && code <= 0xdbff) {
        if (cursor->offset + 2 > cursor->length ||
            cursor->bytes[cursor->offset++] != '\\' ||
            cursor->bytes[cursor->offset++] != 'u') return 0;
        int low = unicode_escape(cursor);
        if (low < 0xdc00 || low > 0xdfff) return 0;
      }
    } else if (byte != '"' && byte != '\\' && byte != '/' && byte != 'b' &&
               byte != 'f' && byte != 'n' && byte != 'r' && byte != 't') {
      return 0;
    }
  }
  return 0;
}

static int parse_value(struct json_cursor *cursor, int depth);

static int parse_object(struct json_cursor *cursor, int depth) {
  if (depth > 32 || !consume(cursor, '{')) return 0;
  if (consume(cursor, '}')) return 1;
  do {
    if (!parse_string(cursor) || !consume(cursor, ':') || !parse_value(cursor, depth + 1)) return 0;
    if (consume(cursor, '}')) return 1;
  } while (consume(cursor, ','));
  return 0;
}

static int parse_array(struct json_cursor *cursor, int depth) {
  if (depth > 32 || !consume(cursor, '[')) return 0;
  if (consume(cursor, ']')) return 1;
  do {
    if (!parse_value(cursor, depth + 1)) return 0;
    if (consume(cursor, ']')) return 1;
  } while (consume(cursor, ','));
  return 0;
}

static int parse_number(struct json_cursor *cursor) {
  size_t start = cursor->offset;
  if (cursor->bytes[cursor->offset] == '-') cursor->offset++;
  if (cursor->offset >= cursor->length) return 0;
  if (cursor->bytes[cursor->offset] == '0') {
    cursor->offset++;
  } else {
    if (cursor->bytes[cursor->offset] < '1' || cursor->bytes[cursor->offset] > '9') return 0;
    while (cursor->offset < cursor->length && cursor->bytes[cursor->offset] >= '0' &&
           cursor->bytes[cursor->offset] <= '9') cursor->offset++;
  }
  if (cursor->offset < cursor->length && cursor->bytes[cursor->offset] == '.') {
    cursor->offset++;
    if (cursor->offset >= cursor->length || cursor->bytes[cursor->offset] < '0' ||
        cursor->bytes[cursor->offset] > '9') return 0;
    while (cursor->offset < cursor->length && cursor->bytes[cursor->offset] >= '0' &&
           cursor->bytes[cursor->offset] <= '9') cursor->offset++;
  }
  if (cursor->offset < cursor->length &&
      (cursor->bytes[cursor->offset] == 'e' || cursor->bytes[cursor->offset] == 'E')) {
    cursor->offset++;
    if (cursor->offset < cursor->length &&
        (cursor->bytes[cursor->offset] == '+' || cursor->bytes[cursor->offset] == '-')) cursor->offset++;
    if (cursor->offset >= cursor->length || cursor->bytes[cursor->offset] < '0' ||
        cursor->bytes[cursor->offset] > '9') return 0;
    while (cursor->offset < cursor->length && cursor->bytes[cursor->offset] >= '0' &&
           cursor->bytes[cursor->offset] <= '9') cursor->offset++;
  }
  return cursor->offset > start;
}

static int parse_literal(struct json_cursor *cursor, const char *literal) {
  size_t length = strlen(literal);
  if (cursor->offset + length > cursor->length ||
      memcmp(cursor->bytes + cursor->offset, literal, length) != 0) return 0;
  cursor->offset += length;
  return 1;
}

static int parse_value(struct json_cursor *cursor, int depth) {
  skip_space(cursor);
  if (cursor->offset >= cursor->length) return 0;
  unsigned char byte = cursor->bytes[cursor->offset];
  if (byte == '{') return parse_object(cursor, depth);
  if (byte == '[') return parse_array(cursor, depth);
  if (byte == '"') return parse_string(cursor);
  if (byte == 't') return parse_literal(cursor, "true");
  if (byte == 'f') return parse_literal(cursor, "false");
  if (byte == 'n') return parse_literal(cursor, "null");
  if (byte == '-' || (byte >= '0' && byte <= '9')) return parse_number(cursor);
  return 0;
}

static int valid_frame(const unsigned char *record, size_t length) {
  if (length < 3 || record[0] != '{' || record[length - 2] != '}' ||
      record[length - 1] != '\n') return 0;
  for (size_t i = 0; i < length - 1; i++) {
    if (record[i] == '\n' || record[i] == '\r' || record[i] == 0) return 0;
  }
  struct json_cursor cursor = {.bytes = record, .length = length - 1, .offset = 0};
  if (!parse_object(&cursor, 0)) return 0;
  skip_space(&cursor);
  return cursor.offset == cursor.length;
}

/**
 * @cc [owner:ghuntley,label:reliability] sdk-atomic-append
 * A complete newline-terminated frame MUST be appended with one kernel write;
 * a private in-flight marker MUST exist before that write, and any short write
 * MUST leave the marker so a restarted helper refuses further appends.
 */
int main(int argc, char **argv) {
  if (argc != 3 || argv[1][0] != '/' || argv[2][0] != '/') return 2;
  int state_dir = open(argv[2], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (state_dir < 0) return 3;
  int lock = openat(state_dir, "writer.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
  if (lock < 0 || flock(lock, LOCK_EX | LOCK_NB) < 0) return 4;
  struct stat marker_info;
  if (fstatat(state_dir, "inflight", &marker_info, AT_SYMLINK_NOFOLLOW) == 0 || errno != ENOENT)
    return 5;
  int output = open(argv[1], O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0600);
  if (output < 0) return 6;

  unsigned char record[MAX_RECORD];
  unsigned char header[4];
  int poisoned = 0;
  for (;;) {
    int read_status = read_full(STDIN_FILENO, header, sizeof header);
    if (read_status == 0) break;
    if (read_status < 0) return 4;
    uint32_t length = ((uint32_t)header[0] << 24) | ((uint32_t)header[1] << 16) |
                      ((uint32_t)header[2] << 8) | (uint32_t)header[3];
    if (length == 0 || length > MAX_RECORD) return 5;
    read_status = read_full(STDIN_FILENO, record, length);
    if (read_status != 1) return 6;

    if (poisoned) {
      if (reply('P') < 0) return 7;
      continue;
    }
    if (!valid_frame(record, length)) {
      if (reply('I') < 0) return 8;
      continue;
    }

    int marker = openat(state_dir, "inflight", O_WRONLY | O_CREAT | O_EXCL |
                        O_NOFOLLOW | O_CLOEXEC, 0600);
    if (marker < 0) {
      poisoned = 1;
      if (reply('P') < 0) return 9;
      continue;
    }
    int marker_synced = fsync(marker);
    int marker_closed = close(marker);
    if (marker_synced < 0 || marker_closed < 0 || fsync(state_dir) < 0) {
      poisoned = 1;
      if (reply('P') < 0) return 9;
      continue;
    }

    size_t write_length = length;
#ifdef SDK_WRITER_TEST_FAULTS
    const char *short_write = getenv("OVERALLS_ANTITHESIS_TEST_SHORT_WRITE");
    if (short_write != NULL && strcmp(short_write, "1") == 0) write_length = length - 1;
#endif
    ssize_t written = write(output, record, write_length);
    if (written != (ssize_t)length) {
      poisoned = 1;
      if (reply('P') < 0) return 9;
      continue;
    }
    if (unlinkat(state_dir, "inflight", 0) < 0) {
      poisoned = 1;
      if (reply('P') < 0) return 11;
      continue;
    }
    (void)fsync(state_dir);
#ifdef SDK_WRITER_TEST_FAULTS
    const char *delay_reply = getenv("OVERALLS_ANTITHESIS_TEST_DELAY_REPLY");
    if (delay_reply != NULL && strcmp(delay_reply, "1") == 0) {
      const struct timespec delay = {.tv_sec = 2, .tv_nsec = 0};
      nanosleep(&delay, NULL);
    }
#endif
    if (reply('W') < 0) return 10;
  }
  return close(output) == 0 ? 0 : 12;
}
