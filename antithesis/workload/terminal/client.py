"""Authenticated browser terminal actions over the real Marshall LiveView."""

from dataclasses import dataclass
from pathlib import Path
from urllib.parse import quote
from uuid import UUID

from access.http import BrowserClient
from access.liveview import LiveView, parse_live_page
from core.outcome import Observation, State


@dataclass(frozen=True)
class CreateReply:
    state: str
    request_id: UUID
    session_id: UUID | None


class TerminalClient:
    def __init__(
        self, browser: BrowserClient, view: LiveView, origin: str, vm_id: UUID, ca_file: Path
    ) -> None:
        self._browser = browser
        self._view = view
        self._origin = origin.rstrip("/")
        self._vm_id = vm_id
        self._ca_file = ca_file

    @classmethod
    def mount(
        cls, browser: BrowserClient, origin: str, vm_id: UUID, ca_file: Path
    ) -> Observation["TerminalClient"]:
        """@cc [owner:ghuntley,label:security;verification] terminal-current-browser-authority
        Terminal mutations MUST use a mounted, authenticated real Marshall
        LiveView and its current browser cookie. A missing/redirected page or
        failed join MUST remain unavailable, never a successful terminal action.
        """
        path = f"/machines/{vm_id}/terminals"
        response = browser.request("GET", f"{origin.rstrip('/')}{path}")
        if response.state is not State.OBSERVED or response.value is None:
            return Observation.unavailable()
        if response.value.status != 200:
            return Observation.unavailable()
        page = parse_live_page(response.value.body)
        if page is None:
            return Observation.unavailable()
        mounted = LiveView.mount(browser, origin, path, page, ca_file)
        if mounted.state is not State.OBSERVED or mounted.value is None:
            return Observation.unavailable()
        return Observation.observed(cls(browser, mounted.value, origin, vm_id, ca_file))

    def create(self, request_id: UUID) -> Observation[CreateReply]:
        """Retry the same immutable request ID when a reply is uncertain."""
        response = self._view.event("terminal_new", {"request_id": str(request_id)})
        if response.state is not State.OBSERVED or response.value is None:
            return Observation.unavailable()
        reply = response.value
        state = reply.get("status")
        echoed = reply.get("request_id")
        session = reply.get("session_id")
        if (
            not isinstance(state, str)
            or state not in ("ready", "pending", "failed")
            or echoed != str(request_id)
        ):
            return Observation.unavailable()
        if state == "ready":
            if not isinstance(session, str):
                return Observation.unavailable()
            try:
                return Observation.observed(CreateReply(state, request_id, UUID(session)))
            except ValueError:
                return Observation.unavailable()
        if session is not None:
            return Observation.unavailable()
        return Observation.observed(CreateReply(state, request_id, None))

    def drop_create_reply(self, request_id: UUID) -> bool:
        """Send on the real mounted channel, then close before reading its reply."""
        sent = self._view.send_event_without_reply("terminal_new", {"request_id": str(request_id)})
        self._view.close()
        return sent

    def reconnect(self) -> Observation["TerminalClient"]:
        return self.mount(self._browser, self._origin, self._vm_id, self._ca_file)

    def kill(self, session_id: UUID) -> Observation[bool]:
        """The event reply only confirms dispatch; guest death needs its oracle."""
        reply = self._view.event("terminal_kill", {"session_id": str(session_id)})
        if reply.state is not State.OBSERVED:
            return Observation.unavailable()
        return Observation.observed(True)

    def ticket(self, session_id: UUID) -> Observation[str]:
        """Consume one private push event for a single-use viewer ticket."""
        reply = self._view.event("terminal_ticket", {"session_id": str(session_id)})
        if reply.state is not State.OBSERVED:
            return Observation.unavailable()
        pushed = self._view.next_push_event("terminal_ticket")
        if pushed.state is not State.OBSERVED or pushed.value is None:
            return Observation.unavailable()
        if pushed.value.get("session_id") != str(session_id):
            return Observation.unavailable()
        ticket = pushed.value.get("ticket")
        if not isinstance(ticket, str) or not 16 <= len(ticket) <= 4096:
            return Observation.unavailable()
        return Observation.observed(ticket)

    def viewer_url(self, session_id: UUID, ticket: str, *, cols: int = 80, rows: int = 24) -> str:
        if not 1 <= cols <= 4096 or not 1 <= rows <= 512:
            raise ValueError("invalid terminal dimensions")
        origin = self._origin.replace("https://", "wss://", 1)
        return (
            f"{origin}/machines/{self._vm_id}/terminals/{session_id}/socket"
            f"?ticket={quote(ticket, safe='')}&cols={cols}&rows={rows}"
        )

    def cookie_header(self, session_id: UUID) -> str:
        return self._browser.cookie_header(
            f"{self._origin}/machines/{self._vm_id}/terminals/{session_id}/socket"
        )

    def ca_file(self) -> Path:
        return self._ca_file

    def close(self) -> None:
        self._view.close()
