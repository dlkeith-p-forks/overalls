"""Verify private SMTP handoff parsing and CSRF/LiveView page extraction."""

from __future__ import annotations

import base64
import hashlib
import http.cookiejar
import os
import subprocess
import unittest
from urllib.request import Request

from access.browser import pending_mutation_refused, pending_read_ok
from access.http import _pinned, hidden_form
from access.liveview import _event_reply, parse_live_page
from access.mail import _message_link
from access.passkey import Authenticator, assertion
from access.session import _token_path
from core.outcome import State


class BrowserHelpersTest(unittest.TestCase):
    def test_synthetic_webauthn_assertion_verifies_for_current_challenge(self) -> None:
        key = subprocess.run(
            ["openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-outform", "DER"],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        ).stdout
        public = subprocess.run(
            ["openssl", "pkey", "-inform", "DER", "-pubout"],
            input=key,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        ).stdout
        raw_id = base64.urlsafe_b64encode(b"fixture-id" * 4).rstrip(b"=").decode("ascii")
        challenge = {
            "id": "challenge-id",
            "publicKey": {
                "challenge": "AQID",
                "rpId": "marshall-a",
                "allowCredentials": [{"id": raw_id}],
            },
        }
        result = assertion(challenge, Authenticator(raw_id, key), "https://marshall-a")
        self.assertIsNotNone(result)
        if result is None:
            return

        def decode(value: str) -> bytes:
            return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))

        signed = (
            decode(result["authenticator_data"])
            + hashlib.sha256(decode(result["client_data_json"])).digest()
        )
        key_fd = os.memfd_create("fixture-public")
        signature_fd = os.memfd_create("fixture-signature")
        try:
            os.write(key_fd, public)
            os.write(signature_fd, decode(result["signature"]))
            verified = subprocess.run(
                [
                    "openssl",
                    "pkeyutl",
                    "-verify",
                    "-pubin",
                    "-inkey",
                    f"/proc/self/fd/{key_fd}",
                    "-sigfile",
                    f"/proc/self/fd/{signature_fd}",
                    "-rawin",
                    "-digest",
                    "sha256",
                ],
                input=signed,
                pass_fds=(key_fd, signature_fd),
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )
        finally:
            os.close(key_fd)
            os.close(signature_fd)
        self.assertEqual(verified.returncode, 0)

    def test_private_smtp_message_matches_recipient_and_message_id(self) -> None:
        link = "https://marshall-a:4443/magic_link/header.payload.signature"
        message = (
            b"Message-ID: <receipt@example.test>\r\n"
            b"To: <actor@example.test>\r\n"
            b"Content-Type: text/plain; charset=utf-8\r\n\r\n"
            + f"Sign in to Overalls: {link}\r\n".encode("ascii")
        )
        entry: dict[str, object] = {
            "recipient": "<actor@example.test>",
            "message_id": "<receipt@example.test>",
            "data_b64": base64.b64encode(message).decode("ascii"),
        }
        found = _message_link(entry, "actor@example.test")
        self.assertIs(found.state, State.OBSERVED)
        self.assertEqual(found.value, link)
        other = _message_link(entry, "other@example.test")
        self.assertIs(other.state, State.OBSERVED)
        self.assertIsNone(other.value)
        entry["message_id"] = "<wrong@example.test>"
        self.assertIs(_message_link(entry, "actor@example.test").state, State.UNAVAILABLE)

    def test_csrf_form_and_liveview_session_are_tied_to_rendered_page(self) -> None:
        page = b"""
        <meta name="csrf-token" content="csrf123">
        <div id="phx-main" data-phx-main data-phx-session="signed-session"
             data-phx-static="static-session"></div>
        <form action="/auth/user/magic_link" method="post">
          <input type="hidden" name="_csrf_token" value="csrf456">
          <input type="hidden" name="user[token]" value="private-token">
          <input type="hidden" name="user[remember_me]" value="true">
        </form>
        """
        form = hidden_form(page, "/auth/user/magic_link")
        self.assertIsNotNone(form)
        if form is None:
            return
        self.assertEqual(form["_csrf_token"], "csrf456")
        self.assertIsNone(hidden_form(page, "/unexpected"))
        live = parse_live_page(page)
        self.assertIsNotNone(live)
        if live is None:
            return
        self.assertEqual(
            (live.csrf, live.session, live.node_id), ("csrf123", "signed-session", "phx-main")
        )

    def test_copied_session_cookie_is_sent_to_dotless_destination_replica(self) -> None:
        original = http.cookiejar.Cookie(
            version=0,
            name="_marshall_key",
            value="session",
            port=None,
            port_specified=False,
            domain="marshall-a.local",
            domain_specified=False,
            domain_initial_dot=False,
            path="/",
            path_specified=True,
            secure=True,
            expires=None,
            discard=False,
            comment=None,
            comment_url=None,
            rest={"HttpOnly": ""},
        )

        def sent(cookie: http.cookiejar.Cookie, url: str) -> str:
            jar = http.cookiejar.CookieJar()
            jar.set_cookie(cookie)
            request = Request(url)
            jar.add_cookie_header(request)
            return request.get_header("Cookie", "")

        self.assertEqual(sent(original, "https://marshall-a/overview"), "_marshall_key=session")
        copied = _pinned(original, "marshall-b")
        self.assertEqual(sent(copied, "https://marshall-b/overview"), "_marshall_key=session")
        self.assertEqual(sent(copied, "https://marshall-a/overview"), "")
        self.assertEqual(original.domain, "marshall-a.local")

    def test_magic_link_from_either_replica_is_accepted(self) -> None:
        origins = ("https://marshall-a", "https://marshall-b")
        self.assertEqual(
            _token_path("https://marshall-b/magic_link/tok", origins), ("/magic_link/tok", "tok")
        )
        self.assertEqual(
            _token_path("https://marshall-a/magic_link/tok", origins), ("/magic_link/tok", "tok")
        )
        self.assertIsNone(_token_path("https://elsewhere/magic_link/tok", origins))
        self.assertIsNone(_token_path("http://marshall-a/magic_link/tok", origins))
        self.assertIsNone(_token_path("https://marshall-a/magic_link/tok?x=1", origins))

    def test_event_reply_is_unwrapped_from_the_reply_diff(self) -> None:
        reply = {"ok": True, "challenge": {"challenge": "abc"}}
        self.assertEqual(_event_reply({"diff": {"r": reply, "0": "x"}}), reply)
        self.assertEqual(_event_reply({"diff": {"0": "x"}}), {"diff": {"0": "x"}})
        self.assertEqual(_event_reply({}), {})

    def test_pending_mfa_read_follows_adr_0160_signed_in_boundary(self) -> None:
        self.assertTrue(pending_read_ok(200, True, False, True))
        # The superseded read-boundary redirect is no longer the contract.
        self.assertFalse(pending_read_ok(302, False, False, True))
        self.assertFalse(pending_read_ok(200, False, False, True))
        self.assertFalse(pending_read_ok(200, True, True, True))
        self.assertFalse(pending_read_ok(200, True, False, False))

    def test_pending_mfa_mutation_requires_no_stored_effect(self) -> None:
        self.assertTrue(pending_mutation_refused(True, False, True))
        self.assertFalse(pending_mutation_refused(False, False, True))
        self.assertFalse(pending_mutation_refused(True, True, True))
        self.assertFalse(pending_mutation_refused(True, False, False))


if __name__ == "__main__":
    unittest.main()
