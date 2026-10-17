"""Closed public operator settings; never parent credentials or private keys."""

import ipaddress
import re
from typing import TypeIs
from urllib.parse import urlsplit

from runtime import SetupError, encode

FIELDS = {"issuer", "accept_terms", "nameservers", "mailbox", "issuer_ca_pem", "trust_pem"}
PEM = re.compile(r"(?:-----BEGIN CERTIFICATE-----\n[A-Za-z0-9+/=\n]+-----END CERTIFICATE-----\n?)+")


def name(value: object) -> TypeIs[str]:
    return (
        isinstance(value, str)
        and 1 <= len(value) <= 253
        and all(
            re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label)
            for label in value.split(".")
        )
    )


def validate(value: object) -> object:
    """@cc [owner:ghuntley,label:security] inception-public-settings-validation
    Parent settings MUST use the closed bounded public schema and explicit
    consent. Only distinct IPv4 authoritative endpoints are permitted. Paths,
    inline credentials and private-key PEM MUST fail before publication.
    """
    if value is None:
        return None
    try:
        if not isinstance(value, dict) or set(value) != FIELDS or value["accept_terms"] is not True:
            raise ValueError()
        issuer = value["issuer"]
        if (
            not isinstance(issuer, str)
            or not 1 <= len(issuer) <= 2048
            or not re.fullmatch(r"[\x21-\x7e]+", issuer)
        ):
            raise ValueError()
        url = urlsplit(issuer)
        if (
            not issuer.startswith("https://")
            or "#" in issuer
            or url.scheme != "https"
            or not name(url.hostname)
            or url.username is not None
            or url.password is not None
            or url.fragment
            or not 1 <= (443 if url.port is None else url.port) <= 65535
            or url.netloc != url.netloc.lower()
        ):
            raise ValueError()
        peers = value["nameservers"]
        if not name(value["mailbox"]) or not isinstance(peers, list) or not 2 <= len(peers) <= 8:
            raise ValueError()
        names, addresses = set(), set()
        for peer in peers:
            if not isinstance(peer, dict) or set(peer) != {"name", "address", "port"}:
                raise ValueError()
            address = peer["address"]
            if not isinstance(address, str):
                raise ValueError()
            ip = ipaddress.IPv4Address(address)
            if (
                not 1 <= ip.packed[0] <= 223
                or str(ip) != address
                or not name(peer["name"])
                or type(peer["port"]) is not int
                or not 1 <= peer["port"] <= 65535
                or peer["name"] in names
                or address in addresses
            ):
                raise ValueError()
            names.add(peer["name"])
            addresses.add(address)
        if len(encode(value)) > 60000:
            raise ValueError()
        for key in ["issuer_ca_pem", "trust_pem"]:
            pem = value[key]
            if pem is not None and (
                not isinstance(pem, str) or not 1 <= len(pem) <= 16384 or not PEM.fullmatch(pem)
            ):
                raise ValueError()
    except (ValueError, TypeError, KeyError):
        raise SetupError("public Inception settings invalid") from None
    return value


def validate_parent(value: object, namespace: str) -> object:
    """@cc [owner:ghuntley,label:security] inception-parent-origin-validation
    Parent discovery MUST bind the assigned namespace and a canonical HTTPS
    origin only. Credentials, IPv6, paths and shell/SSH syntax MUST be rejected.
    This public metadata MUST NOT confer parent or child access authority.
    """
    if value is None:
        return None
    try:
        if not isinstance(value, dict) or set(value) != {"origin", "label", "zone"}:
            raise ValueError()
        if (
            not isinstance(value["label"], str)
            or not 34 <= len(value["label"]) <= 63
            or not re.fullmatch(r"[a-z][a-z0-9-]*-[0-9a-f]{32}", value["label"])
            or not name(value["zone"])
            or value["label"] + ".inception." + value["zone"] != namespace
        ):
            raise ValueError()
        origin = value["origin"]
        if not isinstance(origin, str) or not 1 <= len(origin) <= 2048:
            raise ValueError()
        url = urlsplit(origin)
        host = url.hostname
        port = 443 if url.port is None else url.port
        if (
            url.scheme != "https"
            or not name(host)
            or not 1 <= port <= 65535
            or url.username is not None
            or url.password is not None
            or url.path
            or url.query
            or url.fragment
            or origin != "https://" + host + ("" if port == 443 else ":" + str(port))
        ):
            raise ValueError()
    except (ValueError, TypeError, KeyError):
        raise SetupError("Inception parent discovery invalid") from None
    return value
