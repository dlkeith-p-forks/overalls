"""Check native system settings and trust from the real guest login environment."""

import json
import os
import tomllib
from pathlib import Path


def mapping(value: object) -> dict[str, object]:
    if not isinstance(value, dict):
        raise ValueError("expected a settings table")
    result: dict[str, object] = {}
    for key, item in value.items():
        if not isinstance(key, str):
            raise ValueError("expected a string settings key")
        result[key] = item
    return result


def main() -> None:
    """@cc [owner:ghuntley,label:verification;security] guest-native-coding-cli-settings
    Real guest login environments MUST provide the verified system CA bundle.
    Native Codex and Claude system configuration MUST select the Ziggy URLs,
    disable approval prompts and sandboxing, and keep the dangerous execution
    mode explicit. No fixture user dotfiles may supply the provider or policy
    configuration required for this probe to pass.
    """
    bundle = "/etc/ssl/certs/ca-certificates.crt"
    for variable in ("CODEX_CA_CERTIFICATE", "SSL_CERT_FILE", "NODE_EXTRA_CA_CERTS"):
        assert os.environ.get(variable) == bundle, variable
    assert Path(bundle).stat().st_size > 0
    with Path("/etc/codex/config.toml").open("rb") as stream:
        codex = mapping(tomllib.load(stream))
    assert codex.get("model_provider") == "ziggy"
    assert codex.get("check_for_update_on_startup") is False
    assert codex.get("approval_policy") == "never"
    assert codex.get("sandbox_mode") == "danger-full-access"
    provider = mapping(mapping(codex.get("model_providers")).get("ziggy"))
    assert provider.get("base_url") == "https://llm.internal/openai/v1"
    assert provider.get("wire_api") == "responses"
    assert provider.get("requires_openai_auth") is False
    assert provider.get("supports_websockets") is False
    claude: object = json.loads(Path("/etc/claude-code/managed-settings.json").read_text())
    claude_settings = mapping(claude)
    assert mapping(claude_settings.get("permissions")).get("defaultMode") == "bypassPermissions"
    assert claude_settings.get("skipDangerousModePermissionPrompt") is True
    assert mapping(claude_settings.get("sandbox")).get("enabled") is False
    environment = mapping(claude_settings.get("env"))
    assert environment.get("ANTHROPIC_BASE_URL") == "https://llm.internal/anthropic"
    assert environment.get("ANTHROPIC_AUTH_TOKEN") == "ziggy"
    assert environment.get("DISABLE_AUTOUPDATER") == "1"
    assert environment.get("FORCE_AUTOUPDATE_PLUGINS") == "0"
    assert environment.get("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC") == "1"
    assert environment.get("NODE_EXTRA_CA_CERTS") == bundle
    assert environment.get("SSL_CERT_FILE") == bundle


if __name__ == "__main__":
    main()
