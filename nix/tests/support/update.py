"""Publish immutable Git fixtures pointing at actual prebuilt NixOS candidates."""

import json as _update_json
from typing import Protocol, TypedDict


class SucceedingMachine(Protocol):
    """Command execution supplied by the composed NixOS test driver machine."""

    def succeed(self, *commands: str, timeout: int | None = None) -> str: ...


class UpdateRevision(TypedDict):
    revision: str
    repository: str
    branch: str


class UpdateStatus(TypedDict, total=False):
    phase: str
    failedPhase: str
    failure: str
    candidate: UpdateRevision
    lastHealthy: UpdateRevision


def update_repository(machine: SucceedingMachine) -> tuple[str, dict[str, str]]:
    machine.succeed("systemctl stop overalls-auto-update.timer")
    candidates: dict[str, str] = _update_json.loads(
        machine.succeed("cat /etc/overalls-update-candidates.json")
    )
    repo = "/var/lib/overalls-update-test/git"
    machine.succeed(f"mkdir -p {repo} && git -C {repo} init -b main")
    machine.succeed(f"git -C {repo} config user.email fixture@example.test")
    machine.succeed(f"git -C {repo} config user.name Fixture")
    return repo, candidates


def update_publish(
    machine: SucceedingMachine, repository: str, candidate: str, message: str
) -> str:
    flake = f"""{{
  inputs.deployment = {{ url = "path:{candidate}"; flake = false; }};
  outputs = {{ self, deployment }}: {{
    nixosConfigurations.host.config.system.build.overallsDeployment = deployment.outPath;
  }};
}}"""
    machine.succeed(f"cat > {repository}/flake.nix <<'NIX'\n{flake}\nNIX")
    machine.succeed(f"git -C {repository} add flake.nix")
    machine.succeed(f"cd {repository} && nix flake lock --offline")
    machine.succeed(
        f"git -C {repository} add flake.lock && git -C {repository} commit --allow-empty -m {message}"
    )
    return machine.succeed(f"git -C {repository} rev-parse HEAD").strip()


def update_status(machine: SucceedingMachine) -> UpdateStatus:
    return _update_json.loads(machine.succeed("overalls-auto-update status"))


def update_success(machine: SucceedingMachine) -> None:
    machine.succeed("systemctl start overalls-auto-update.service", timeout=300)
    assert update_status(machine)["phase"] == "healthy"
