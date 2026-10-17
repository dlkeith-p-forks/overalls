/**
 * @cc [owner:ghuntley,label:recovery;capacity] boot-log-poll-single-flight
 * Polling MUST hold at most one current request or emulator write at a time. EOF and
 * refused reads MUST wait two seconds before retrying. Pausing MUST cancel the
 * timer and discard late request replies; an active write MUST finish before
 * another request. Hiding MUST retain the request fence until its cancelled
 * reply arrives; disconnect and destruction invalidate the old transport's
 * callback. Destroyed, hidden or disconnected views MUST NOT poll.
 */
export class BootLogPoller {
  /**
   * @param {() => boolean} active
   * @param {() => number} cursor
   * @param {(cursor: number, receive: (reply: unknown) => void) => boolean} fetch
   * @param {(reply: unknown, finished: (more: boolean) => void) => void} consume
   */
  constructor(active, cursor, fetch, consume) {
    this.active = active;
    this.cursor = cursor;
    this.fetch = fetch;
    this.consume = consume;
    this.timer = 0;
    this.closed = false;
    /** @type {{writing: boolean, cancelled: boolean} | null} */
    this.pending = null;
  }

  start() {
    if (this.closed || !this.active() || this.pending || this.timer) return;
    const token = {writing: false, cancelled: false};
    this.pending = token;
    const sent = this.fetch(this.cursor(), (reply) => {
      if (this.pending !== token) return;
      if (token.cancelled || !this.active()) {
        this.pending = null;
        this.schedule(2000);
        return;
      }
      token.writing = true;
      this.consume(reply, (more) => {
        if (this.pending !== token) return;
        this.pending = null;
        this.schedule(more ? 0 : 2000);
      });
    });
    if (!sent && this.pending === token) {
      this.pending = null;
      this.schedule(2000);
    }
  }

  /** @param {number} delay */
  schedule(delay) {
    clearTimeout(this.timer);
    this.timer = 0;
    if (this.closed || !this.active()) return;
    this.timer = setTimeout(() => {
      this.timer = 0;
      this.start();
    }, delay);
  }

  /** @param {boolean} [disconnected] */
  pause(disconnected = false) {
    clearTimeout(this.timer);
    this.timer = 0;
    if (this.pending && !this.pending.writing) {
      if (disconnected) this.pending = null;
      else this.pending.cancelled = true;
    }
  }

  destroy() {
    this.pause(true);
    this.closed = true;
    this.pending = null;
  }
}
