"""Verify private SMTP handoff parsing and CSRF/LiveView page extraction."""

from __future__ import annotations

import base64
import hashlib
import os
import subprocess
import unittest

from access.http import hidden_form
from access.liveview import parse_live_page
from access.mail import _message_link
from access.passkey import Authenticator, assertion
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
        <div id="phx-main" data-phx-main="true" data-phx-session="signed-session"
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


if __name__ == "__main__":
    unittest.main()
