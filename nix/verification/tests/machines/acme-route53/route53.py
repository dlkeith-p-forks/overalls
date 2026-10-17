"""Loopback Route 53/DNS fixture with real SigV4 verification and TXT changes."""

import hashlib
import hmac
import json
import re
import ssl
import threading
from datetime import UTC, datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qsl, quote, urlsplit
from xml.etree import ElementTree as ET

from dnslib import NS, QTYPE, RR, SOA, TXT, A, DNSRecord
from dnslib.server import BaseResolver, DNSLogger, DNSServer

ROOT = Path("/run/overalls-test-acme")
FQDN = "_acme-challenge.control.example.test."
ZONE = "ZOVERALLS"
NSPACE = "https://route53.amazonaws.com/doc/2013-04-01/"
LOCK = threading.Lock()
RECORDS: list[str] = []
STATS = {
    "upserts": 0,
    "deletes": 0,
    "dns_answers": 0,
    "denied": 0,
    "api_requests": 0,
    "dns_queries": 0,
}
KEYS: dict[str, str] = json.loads((ROOT / "keys.json").read_text())


def count(name: str) -> None:
    with LOCK:
        STATS[name] += 1
        temporary = ROOT / "stats.json.new"
        temporary.write_text(json.dumps(STATS))
        temporary.replace(ROOT / "stats.json")
        print(json.dumps({"event": "route53.fixture_activity", **STATS}), flush=True)


# @cc [owner:ghuntley,label:verification] route53-authenticated-dns-fixture
# The fixture MUST verify the actual AWS signature and change the TXT record
# queried by Lego and Pebble. It MUST NOT bypass ACME DNS validation.
def authenticated(handler: "Route53", body: bytes) -> bool:
    header = handler.headers.get("Authorization", "")
    match = re.fullmatch(
        r"AWS4-HMAC-SHA256 Credential=([^,]+), SignedHeaders=([^,]+), Signature=([a-f0-9]{64})",
        header,
    )
    if not match:
        return False
    credential, signed, signature = match.groups()
    access, date, region, service, final = credential.split("/")
    if (access, region, service, final) != (KEYS["access"], "us-east-1", "route53", "aws4_request"):
        return False
    timestamp = handler.headers["X-Amz-Date"]
    observed = datetime.strptime(timestamp, "%Y%m%dT%H%M%SZ").replace(tzinfo=UTC)
    if abs((datetime.now(UTC) - observed).total_seconds()) > 300 or date != timestamp[:8]:
        return False
    url = urlsplit(handler.path)
    query = "&".join(
        quote(name, safe="-_.~") + "=" + quote(value, safe="-_.~")
        for name, value in sorted(parse_qsl(url.query, keep_blank_values=True))
    )
    headers = "".join(
        name + ":" + " ".join(handler.headers[name].split()) + "\n" for name in signed.split(";")
    )
    canonical = "\n".join(
        (handler.command, url.path, query, headers, signed, hashlib.sha256(body).hexdigest())
    )
    scope = "/".join((date, region, service, final))
    to_sign = "\n".join(
        ("AWS4-HMAC-SHA256", timestamp, scope, hashlib.sha256(canonical.encode()).hexdigest())
    )
    key = ("AWS4" + KEYS["secret"]).encode()
    for value in (date, region, service, final):
        key = hmac.digest(key, value.encode(), "sha256")
    return hmac.compare_digest(
        hmac.new(key, to_sign.encode(), hashlib.sha256).hexdigest(), signature
    )


class Route53(BaseHTTPRequestHandler):
    def log_message(self, *_arguments: object) -> None:
        pass

    def response(self, name: str, contents: str, status: int = 200) -> None:
        data = f'<{name} xmlns="{NSPACE}">{contents}</{name}>'.encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/xml")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def denied(self) -> None:
        count("denied")
        # Deliberately reflect fixture credentials in the remote error. The
        # production client wrapper must prevent this diagnostic reaching logs.
        self.response(
            "ErrorResponse",
            "<Error><Code>AccessDenied</Code><Message>"
            + KEYS["access"]
            + KEYS["secret"]
            + "</Message></Error>",
            403,
        )

    def dispatch(self) -> None:
        global RECORDS
        count("api_requests")
        length = int(self.headers.get("Content-Length", "0"))
        if not 0 <= length <= 65536:
            raise ValueError("oversized request")
        body = self.rfile.read(length)
        if not authenticated(self, body) or (ROOT / "deny").exists():
            self.denied()
            return
        path = urlsplit(self.path).path
        change = "<ChangeInfo><Id>/change/fixture</Id><Status>INSYNC</Status><SubmittedAt>2026-09-16T00:00:00Z</SubmittedAt></ChangeInfo>"
        if self.command == "GET" and path == "/2013-04-01/change/fixture":
            self.response("GetChangeResponse", change)
        elif path == f"/2013-04-01/hostedzone/{ZONE}/rrset" and self.command == "GET":
            records = "".join(
                "<ResourceRecord><Value>&quot;" + value + "&quot;</Value></ResourceRecord>"
                for value in RECORDS
            )
            record_set = (
                f"<ResourceRecordSet><Name>{FQDN}</Name><Type>TXT</Type><TTL>10</TTL><ResourceRecords>{records}</ResourceRecords></ResourceRecordSet>"
                if records
                else ""
            )
            self.response(
                "ListResourceRecordSetsResponse",
                "<ResourceRecordSets>"
                + record_set
                + "</ResourceRecordSets><IsTruncated>false</IsTruncated><MaxItems>100</MaxItems>",
            )
        elif path == f"/2013-04-01/hostedzone/{ZONE}/rrset" and self.command == "POST":
            changes = ET.fromstring(body).findall(".//{*}Change")
            if len(changes) != 1:
                raise ValueError("invalid change")
            action = changes[0].findtext("{*}Action")
            record = changes[0].find("{*}ResourceRecordSet")
            if record.findtext("{*}Name") != FQDN or record.findtext("{*}Type") != "TXT":
                raise ValueError("wrong zone record")
            values = [
                json.loads(element.text)
                for element in record.findall("{*}ResourceRecords/{*}ResourceRecord/{*}Value")
            ]
            if not values or any(not re.fullmatch(r"[A-Za-z0-9_-]{43}", value) for value in values):
                raise ValueError("invalid TXT values")
            if action == "UPSERT":
                RECORDS = values
                count("upserts")
            elif action == "DELETE" and values == RECORDS:
                RECORDS = []
                count("deletes")
            else:
                raise ValueError("unsupported change")
            self.response("ChangeResourceRecordSetsResponse", change)
        else:
            raise ValueError("unsupported route")

    def do_GET(self) -> None:
        try:
            self.dispatch()
        except Exception:
            self.denied()

    do_POST = do_GET


class DNS(BaseResolver):
    def resolve(self, request: DNSRecord, _handler: object) -> DNSRecord:
        count("dns_queries")
        reply = request.reply()
        reply.header.aa = 1
        name, kind = str(request.q.qname), QTYPE[request.q.qtype]
        if kind == "SOA" and name == "example.test.":
            reply.add_answer(
                RR(
                    name,
                    QTYPE.SOA,
                    rdata=SOA("ns.example.test.", "hostmaster.example.test.", (1, 60, 60, 60, 1)),
                    ttl=1,
                )
            )
        elif kind == "NS" and name == "example.test.":
            reply.add_answer(RR(name, QTYPE.NS, rdata=NS("ns.example.test."), ttl=1))
        elif kind == "A" and name in ("ns.example.test.", "control.example.test."):
            reply.add_answer(RR(name, QTYPE.A, rdata=A("127.0.0.1"), ttl=1))
        elif kind == "TXT" and name == FQDN:
            for value in RECORDS:
                reply.add_answer(RR(name, QTYPE.TXT, rdata=TXT(value), ttl=1))
            if RECORDS:
                count("dns_answers")
        return reply


if __name__ == "__main__":
    (ROOT / "stats.json").write_text(json.dumps(STATS))
    for tcp in (False, True):
        DNSServer(
            DNS(),
            address="127.0.0.1",
            port=53,
            tcp=tcp,
            logger=DNSLogger(log="-request,-reply,-truncated,-error", prefix=False),
        ).start_thread()
    server = ThreadingHTTPServer(("127.0.0.1", 8443), Route53)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain("/run/overalls-test/tls.crt", "/run/overalls-test/tls.key")
    server.socket = context.wrap_socket(server.socket, server_side=True)
    server.serve_forever()
