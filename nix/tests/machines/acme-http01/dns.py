"""Local DNS with driver-selected ingress; Pebble still validates real HTTP."""

import json
import threading
from collections.abc import Callable
from pathlib import Path

from dnslib import QTYPE, RR, A, DNSRecord
from dnslib.server import BaseResolver, DNSServer

ROOT = Path("/run/overalls-http01-dns")
LOCK = threading.Lock()


class Resolver(BaseResolver):
    def __init__(self) -> None:
        self.queries = 0

    def resolve(self, request: DNSRecord, _handler: object) -> DNSRecord:
        """@cc [owner:ghuntley,label:verification] http01-real-selected-ingress
        DNS MAY select any configured frontend but MUST NOT bypass challenge
        validation or return a fabricated HTTP success. Record only IP counts.
        """
        reply = request.reply()
        if str(request.q.qname).lower() == "control.example.test." and request.q.qtype == QTYPE.A:
            with LOCK:
                path = ROOT / "addresses.json"
                addresses: list[str] = json.loads(path.read_text()) if path.exists() else []
                stats_file = ROOT / "stats.json"
                stats: dict[str, int] = (
                    json.loads(stats_file.read_text()) if stats_file.exists() else {}
                )
                if addresses:
                    # Rotate the first answer as well as publishing every address.
                    offset = self.queries % len(addresses)
                    self.queries += 1
                    addresses = addresses[offset:] + addresses[:offset]
                for address in addresses:
                    reply.add_answer(RR(request.q.qname, QTYPE.A, ttl=0, rdata=A(address)))
                    stats[address] = stats.get(address, 0) + 1
                stats_file.write_text(json.dumps(stats))
        return reply


if __name__ == "__main__":
    # Disable dnslib's request log; the private counters are sufficient evidence.
    class Quiet:
        def __getattr__(self, _name: str) -> Callable[..., None]:
            return lambda *_args: None

    DNSServer(Resolver(), port=53, address="127.0.0.1", logger=Quiet()).start()
