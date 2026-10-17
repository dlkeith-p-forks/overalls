/**
 * @typedef {object} TicketWorkspace
 * @property {boolean} liveConnected
 * @property {string | null} activeId
 * @property {Map<string, number>} ticketTimers
 * @property {Map<string, {attach: (ticket: string) => void}>} panes
 */

/**
 * @cc [owner:ghuntley,label:recovery] terminal-ticket-current-selection
 * A delayed ticket reply MUST NOT attach a pane that is no longer selected or
 * while LiveView is disconnected. Its retry timer MUST still be removed so a
 * later selection can request fresh authority. Malformed replies MUST leave
 * pending requests and pane attachments unchanged.
 */
/** @param {TicketWorkspace} workspace @param {unknown} reply @returns {void} */
export function deliverTicket(workspace, reply) {
  if (typeof reply !== "object" || reply === null ||
      !("session_id" in reply) || typeof reply.session_id !== "string" ||
      !("ticket" in reply) || typeof reply.ticket !== "string") return;
  const {session_id, ticket} = reply;
  clearTimeout(workspace.ticketTimers.get(session_id));
  workspace.ticketTimers.delete(session_id);
  if (!workspace.liveConnected || workspace.activeId !== session_id) return;
  workspace.panes.get(session_id)?.attach(ticket);
}
