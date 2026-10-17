"""Stage and validate exact executable Antithesis command templates."""

from __future__ import annotations

import argparse
import ast
import hashlib
import json
import os
import re
import shutil
import tempfile
from dataclasses import dataclass
from pathlib import Path

from assertions import python_calls
from identity import (
    IMAGE_CATALOG_ROOT,
    STAGED_CATALOG,
    command,
    file_record,
    images,
    selected_stages,
    sha256,
    validate_compose_secrets,
)
from schema import (
    EvidenceError,
    Json,
    arr,
    atomic_json,
    canonical,
    field,
    narrow_json,
    obj,
    read_json,
    string,
)

TEMPLATE = re.compile(r"^[a-z][a-z0-9_]*$")
CONFIG = re.compile(r"^[a-z][a-z0-9-]*$")
COMMAND = re.compile(r"^(?:serial_driver|singleton_driver|first|helper)_[a-z][a-z0-9_]*\.py$")


@dataclass(frozen=True)
class Selection:
    name: str
    compose_files: tuple[str, ...]
    templates: tuple[str, ...]
    runtime_packages: tuple[str, ...]
    singleton_templates: tuple[str, ...]
    services: tuple[str, ...]
    workload_environment: tuple[str, ...]
    bootstrap_template: str


def strings(data: dict[str, Json], key: str, *, allow_empty: bool = False) -> tuple[str, ...]:
    values = tuple(string(item, key) for item in arr(field(data, key), key))
    if (not values and not allow_empty) or len(values) != len(set(values)):
        raise EvidenceError(
            f"{key} must be a unique list" + ("" if allow_empty else " with entries")
        )
    return values


def read_selection(path: Path) -> Selection:
    data = obj(read_json(path), "template selection")
    expected = {
        "format",
        "name",
        "compose_files",
        "templates",
        "runtime_packages",
        "singleton_templates",
        "services",
        "workload_environment",
        "bootstrap_template",
    }
    if set(data) != expected or data["format"] != 1:
        raise EvidenceError("invalid template selection schema")
    selection = Selection(
        string(field(data, "name"), "selection name"),
        strings(data, "compose_files"),
        strings(data, "templates"),
        strings(data, "runtime_packages"),
        strings(data, "singleton_templates", allow_empty=True),
        strings(data, "services"),
        strings(data, "workload_environment"),
        string(field(data, "bootstrap_template"), "bootstrap_template"),
    )
    if CONFIG.fullmatch(selection.name) is None or any(
        TEMPLATE.fullmatch(name) is None
        for name in (*selection.templates, *selection.runtime_packages)
    ):
        raise EvidenceError("invalid template or runtime package name")
    if not set(selection.singleton_templates).issubset(selection.templates):
        raise EvidenceError("singleton templates must be selected templates")
    if selection.bootstrap_template != selection.name:
        raise EvidenceError("bootstrap template and selected config differ")
    return selection


def module_dependencies(path: Path, workload: Path, packages: tuple[str, ...]) -> set[Path]:
    tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    found: set[Path] = set()
    for node in ast.walk(tree):
        names: list[str] = []
        optional_submodules: list[str] = []
        if isinstance(node, ast.Import):
            names = [alias.name for alias in node.names]
        elif isinstance(node, ast.ImportFrom):
            if node.level:
                if not path.is_relative_to(workload):
                    raise EvidenceError(f"relative runtime import outside workload: {path}")
                containing = list(path.relative_to(workload).parts[:-1])
                if node.level > len(containing):
                    raise EvidenceError(f"relative runtime import escapes workload: {path}")
                base = containing[: len(containing) - node.level + 1]
                if node.module:
                    base.extend(node.module.split("."))
                module = ".".join(base)
            else:
                module = node.module or ""
            names = [module] if module else []
            optional_submodules = [
                f"{module}.{alias.name}" for alias in node.names if module and alias.name != "*"
            ]
        for name in names:
            package = name.split(".", 1)[0]
            if package not in packages:
                if (workload / package / "__init__.py").is_file():
                    raise EvidenceError(
                        f"selected runtime import escapes package roster: {path}: {name}"
                    )
                continue
            source = workload.joinpath(*name.split("."))
            matching = [
                candidate
                for candidate in (source.with_suffix(".py"), source / "__init__.py")
                if candidate.is_file()
            ]
            if len(matching) != 1:
                raise EvidenceError(f"selected runtime import has no exact source: {path}: {name}")
            found.add(matching[0])
        for name in optional_submodules:
            package = name.split(".", 1)[0]
            if package not in packages:
                if (workload / package / "__init__.py").is_file():
                    raise EvidenceError(
                        f"selected runtime import escapes package roster: {path}: {name}"
                    )
                continue
            source = workload.joinpath(*name.split("."))
            matching = [
                candidate
                for candidate in (source.with_suffix(".py"), source / "__init__.py")
                if candidate.is_file()
            ]
            if len(matching) > 1:
                raise EvidenceError(f"ambiguous selected runtime import: {path}: {name}")
            found.update(matching)
    return found


def package_initializers(module: Path, workload: Path) -> tuple[Path, ...]:
    """Ancestor ``__init__.py`` files that importing ``module`` also executes."""
    parts = module.relative_to(workload).parts[:-1]
    if module.name == "__init__.py":
        parts = parts[:-1]
    return tuple(
        initializer
        for depth in range(1, len(parts) + 1)
        if (initializer := workload.joinpath(*parts[:depth], "__init__.py")).is_file()
    )


def selected_files(root: Path, selection: Selection) -> tuple[list[Path], list[Path]]:
    """@cc [owner:ghuntley,label:verification] thin-selected-commands
    A selected test command or helper MUST NOT contain an SDK assertion
    callsite of its own; assertions live in traced workload modules so the
    staged catalog covers every selected callsite, including ones that never
    run. Staging MUST refuse a command that declares one.
    """
    tests = root / "antithesis/test/v1"
    workload = root / "antithesis/workload"
    selected: list[Path] = []
    commands: list[Path] = []
    for template in selection.templates:
        directory = tests / template
        if not directory.is_dir():
            raise EvidenceError(f"missing selected template {directory}")
        files = sorted(path for path in directory.iterdir() if path.name != "__pycache__")
        if not files:
            raise EvidenceError(f"empty selected template {template}")
        if (
            template in selection.singleton_templates
            and sum(not path.name.startswith("helper_") for path in files) != 1
        ):
            raise EvidenceError(f"singleton template must contain exactly one command: {template}")
        for path in files:
            if not path.is_file() or path.is_symlink() or COMMAND.fullmatch(path.name) is None:
                raise EvidenceError(f"unsupported selected template member {path}")
            selected.append(path)
            if not path.name.startswith("helper_"):
                commands.append(path)
    if not commands:
        raise EvidenceError("selection has no test commands")
    for path in selected:
        if python_calls(path, root):
            raise EvidenceError(f"selected test command declares SDK assertions: {path}")
    bootstrap = workload / "core/bootstrap.py"
    if not bootstrap.is_file():
        raise EvidenceError("selected bootstrap source is missing")
    dependencies: set[Path] = set()
    pending: list[Path] = []

    def require(module: Path) -> None:
        for candidate in (module, *package_initializers(module, workload)):
            if candidate not in dependencies:
                dependencies.add(candidate)
                pending.append(candidate)

    require(bootstrap)
    pending.extend(commands)
    while pending:
        path = pending.pop()
        for dependency in module_dependencies(path, workload, selection.runtime_packages):
            require(dependency)
    # Every runtime package used by selected commands needs a selected catalog
    # source. The staged catalog tree itself is checked during freeze.
    for dependency in dependencies:
        if dependency.relative_to(workload).parts[0] not in selection.runtime_packages:
            raise EvidenceError(f"unselected runtime dependency {dependency}")
    return selected, sorted(dependencies)


def manifest(root: Path, selection: Selection) -> dict[str, Json]:
    """@cc [owner:ghuntley,label:verification] selected-command-closure
    A selected image MUST expose exactly its named command templates and bind
    the traced local runtime imports, including executed package initializers,
    to their source hashes. Missing source or unsupported template members MUST
    stop staging; unselected optional test commands MUST stay outside the image.
    Other workload modules may be bundled but enter neither the selected
    assertion roster nor the image's assertion catalog without a traced import.
    """
    files, dependencies = selected_files(root, selection)
    tests = root / "antithesis/test"
    bootstrap_source = root / "antithesis/workload/core/bootstrap.py"
    bootstrap_tree = ast.parse(
        bootstrap_source.read_text(encoding="utf-8"), filename=str(bootstrap_source)
    )
    declared = []
    for node in ast.walk(bootstrap_tree):
        if (
            isinstance(node, ast.Call)
            and isinstance(node.func, ast.Name)
            and node.func.id == "setup_complete"
        ):
            if len(node.args) != 1 or not isinstance(node.args[0], ast.Dict):
                raise EvidenceError("bootstrap setup template must be literal")
            argument = node.args[0]
            for key, value in zip(argument.keys, argument.values, strict=True):
                if (
                    isinstance(key, ast.Constant)
                    and key.value == "template"
                    and isinstance(value, ast.Constant)
                    and isinstance(value.value, str)
                ):
                    declared.append(value.value)
    if set(declared) != {"control-core", "repository-origin", "access-smtp"} or len(declared) != 3:
        raise EvidenceError("bootstrap must declare exactly the reviewed setup templates")
    if selection.bootstrap_template not in declared:
        raise EvidenceError("bootstrap completion template differs from selected config")
    commands = [
        str(path.relative_to(root)) for path in files if not path.name.startswith("helper_")
    ]
    data = obj(
        narrow_json(
            {
                "format": 1,
                "selection": selection.name,
                "compose_files": list(selection.compose_files),
                "templates": list(selection.templates),
                "runtime_packages": list(selection.runtime_packages),
                "singleton_templates": list(selection.singleton_templates),
                "services": list(selection.services),
                "workload_environment": list(selection.workload_environment),
                "bootstrap_template": selection.bootstrap_template,
                "files": [file_record(path, root) for path in files],
                "commands": commands,
                "runtime_dependencies": [file_record(path, root) for path in dependencies],
                "image_command_root": "/opt/antithesis/test/v1",
                "image_catalog_root": IMAGE_CATALOG_ROOT,
            }
        ),
        "command manifest",
    )
    if any(not path.startswith(str(tests.relative_to(root)) + "/v1/") for path in commands):
        raise EvidenceError("command escapes Antithesis test tree")
    data["manifest_sha256"] = hashlib.sha256(
        json.dumps(data, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    ).hexdigest()
    return data


def validate_compose(selection: Selection, rendered: dict[str, Json]) -> None:
    services = obj(field(rendered, "services"), "Compose services")
    if set(services) != set(selection.services):
        raise EvidenceError(f"selected Compose services differ from {selection.name} prerequisites")
    workload = obj(field(services, "workload"), "workload service")
    environment = obj(field(workload, "environment"), "workload environment")
    if not set(selection.workload_environment).issubset(environment):
        raise EvidenceError("selected workload fixture environment is incomplete")
    if (
        string(field(environment, "ANTITHESIS_FIXTURE_MANIFEST"), "fixture manifest")
        != "/run/overalls-secrets/fixture.json"
    ):
        raise EvidenceError("workload fixture manifest path differs from selected bootstrap")
    if string(field(environment, "ANTITHESIS_DB_HOST"), "database host") != "pg":
        raise EvidenceError("selected database host differs from real primary")
    origins = string(field(environment, "ANTITHESIS_MARSHALL_URLS"), "Marshall origins").split(",")
    if set(origins) != {"https://marshall-a", "https://marshall-b"}:
        raise EvidenceError("selected Marshall origins differ from two real replicas")
    depends = obj(field(workload, "depends_on"), "workload dependencies")
    for name in ("pg", "marshall-a", "marshall-b", "enrollment", "lilly-a"):
        dependency = obj(field(depends, name), f"workload dependency {name}")
        if field(dependency, "condition") != "service_healthy":
            raise EvidenceError(f"selected prerequisite is not health-gated: {name}")
    volumes = arr(field(workload, "volumes"), "workload volumes")
    targets = {
        string(field(obj(value, "workload volume"), "target"), "workload volume target")
        for value in volumes
    }
    for key in (
        "ANTITHESIS_CA_FILE",
        "ANTITHESIS_FIXTURE_MANIFEST",
        "ANTITHESIS_DB_PASSWORD_FILE",
        "ANTITHESIS_CONTROL_CREDENTIAL_FILE",
    ):
        path = string(field(environment, key), key)
        if not any(
            path == target or path.startswith(target.rstrip("/") + "/") for target in targets
        ):
            raise EvidenceError(f"selected fixture {key} lacks a mounted volume")
    request_root = string(
        field(environment, "ANTITHESIS_CONTROL_REQUEST_DIR"), "Control request root"
    ).rstrip("/")
    if {request_root + "/requests", request_root + "/results"} - targets:
        raise EvidenceError("Control request/result handoff volumes are incomplete")
    if selection.name == "control-core":
        if "ANTITHESIS_BOOTSTRAP_PROFILE" in environment:
            raise EvidenceError("default selection must use the default bootstrap profile")
    elif selection.name == "repository-origin":
        if environment.get("ANTITHESIS_BOOTSTRAP_PROFILE") != "repository-origin":
            raise EvidenceError("repository bootstrap profile differs from selected commands")
        for name, dependency_name in (("enrico", "enrico"), ("origin", "origin")):
            owner = workload if name == "enrico" else obj(field(services, "enrico"), "enrico")
            owner_dependencies = obj(field(owner, "depends_on"), f"{name} dependencies")
            dependency = obj(field(owner_dependencies, dependency_name), dependency_name)
            if field(dependency, "condition") != "service_healthy":
                raise EvidenceError(f"{dependency_name} is not health-gated")
        expected = {
            "ANTITHESIS_ENRICO_URL": "https://enrico.fleet.internal:5445",
            "ANTITHESIS_ORIGIN_ADMIN_URL": "http://origin-fixture:8080",
        }
        for key, value in expected.items():
            if environment.get(key) != value:
                raise EvidenceError(f"repository fixture endpoint mismatch: {key}")
        for key in (
            "ANTITHESIS_ENRICO_CA_FILE",
            "ANTITHESIS_ENRICO_TOKEN_FILE",
            "ANTITHESIS_ENRICO_MIRROR_ROOT",
            "ANTITHESIS_ENRICO_OBSERVER_FILE",
            "ANTITHESIS_ORIGIN_CA_FILE",
            "ANTITHESIS_ORIGIN_ADMIN_TOKEN_FILE",
            "ANTITHESIS_REPOSITORY_FIXTURE_FILE",
        ):
            path = string(field(environment, key), key)
            if not any(
                path == target or path.startswith(target.rstrip("/") + "/") for target in targets
            ):
                raise EvidenceError(f"repository fixture {key} lacks a mounted volume")
        enrico_control = string(
            field(environment, "ANTITHESIS_ENRICO_CONTROL_ROOT"), "Enrico control root"
        ).rstrip("/")
        if {enrico_control + "/requests", enrico_control + "/results"} - targets:
            raise EvidenceError("repository control request/result volumes are incomplete")
    elif selection.name == "access-smtp":
        if environment.get("ANTITHESIS_BOOTSTRAP_PROFILE") != "access-smtp":
            raise EvidenceError("access bootstrap profile differs from selected commands")
        dependency = obj(field(depends, "smtp"), "SMTP dependency")
        if field(dependency, "condition") != "service_healthy":
            raise EvidenceError("SMTP fixture is not health-gated")
        if environment.get("ANTITHESIS_SMTP_ADMIN_ORIGIN") != "https://smtp.fixture.test:8444":
            raise EvidenceError("SMTP admin endpoint differs from selected fixture")
        for key in (
            "ANTITHESIS_SMTP_CA_FILE",
            "ANTITHESIS_SMTP_ADMIN_TOKEN_FILE",
            "ANTITHESIS_ACCESS_FIXTURE_FILE",
        ):
            path = string(field(environment, key), key)
            if not any(
                path == target or path.startswith(target.rstrip("/") + "/") for target in targets
            ):
                raise EvidenceError(f"SMTP fixture {key} lacks a mounted volume")
    else:
        raise EvidenceError("selection has no reviewed bootstrap prerequisite validator")


def rendered_compose(root: Path, selection: Selection) -> dict[str, Json]:
    arguments = [
        argument for path in selection.compose_files for argument in ("-f", str(root / path))
    ]
    rendered = obj(
        narrow_json(
            json.loads(command(["docker-compose", *arguments, "config", "--format", "json"]))
        ),
        "rendered Compose",
    )
    validate_compose_secrets(rendered)
    validate_compose(selection, rendered)
    selected_stages(rendered)
    return rendered


def hosted_compose(rendered: dict[str, Json]) -> dict[str, Json]:
    """Strip local build inputs; keep local image tags for Snouty's push step."""
    hosted = obj(narrow_json(rendered), "hosted Compose")
    for key in tuple(hosted):
        if key.startswith("x-"):
            del hosted[key]
    services = obj(field(hosted, "services"), "hosted services")
    for name, item in services.items():
        service = obj(item, f"hosted service {name}")
        service.pop("build", None)
        if "env_file" in service or "secrets" in service or "configs" in service:
            raise EvidenceError(f"hosted service {name} references a local config or secret file")
        for volume in arr(service.get("volumes", []), f"{name} volumes"):
            mounted = obj(volume, f"{name} volume")
            if mounted.get("type") != "volume":
                raise EvidenceError(f"hosted service {name} has a local bind or unsupported mount")
            string(field(mounted, "source"), f"{name} volume source")
    return hosted


def materialization(root: Path, selection: Selection, engine: str, output: Path) -> dict[str, Json]:
    expected = root / "antithesis/runtime/configs" / selection.name
    if output.resolve() != expected:
        raise EvidenceError(f"profile config must be materialized at {expected}")
    rendered = rendered_compose(root, selection)
    hosted = hosted_compose(rendered)
    image_data = images(root, selected_stages(rendered), engine)
    receipt = obj(
        narrow_json(
            {
                "format": 1,
                "selection": selection.name,
                "compose_files": list(selection.compose_files),
                "engine": engine,
                "rendered_sha256": sha256(canonical(rendered)),
                "config_sha256": sha256(canonical(hosted)),
                "images": image_data,
            }
        ),
        "materialization receipt",
    )
    if output.exists() and {path.name for path in output.iterdir()} - {
        "docker-compose.yaml",
        "materialization.json",
    }:
        raise EvidenceError("private config directory contains unreviewed files")
    output.mkdir(parents=True, exist_ok=True)
    atomic_json(output / "docker-compose.yaml", hosted)
    atomic_json(output / "materialization.json", receipt)
    return receipt


def verify_materialization(
    root: Path,
    selection: Selection,
    engine: str,
    rendered: dict[str, Json],
    image_data: dict[str, Json],
) -> dict[str, Json]:
    output = root / "antithesis/runtime/configs" / selection.name
    hosted = hosted_compose(rendered)
    receipt = obj(read_json(output / "materialization.json"), "materialization receipt")
    expected: dict[str, Json] = {
        "format": 1,
        "selection": selection.name,
        "compose_files": list(selection.compose_files),
        "engine": engine,
        "rendered_sha256": sha256(canonical(rendered)),
        "config_sha256": sha256(canonical(hosted)),
        "images": image_data,
    }
    if receipt != expected or read_json(output / "docker-compose.yaml") != hosted:
        raise EvidenceError("hosted profile config or image IDs differ from materialized graph")
    if {path.name for path in output.iterdir()} != {"docker-compose.yaml", "materialization.json"}:
        raise EvidenceError("hosted config directory contains extra or missing files")
    return receipt


def stage(root: Path, selection: Selection, output: Path) -> dict[str, Json]:
    """@cc [owner:ghuntley,label:verification] selection-scoped-catalog
    The staged Antithesis catalog MUST contain exactly the manifest's runtime
    dependencies, as one ``workload`` module tree, so the hosted Python
    instrumentor declares every assertion reachable from the selected commands
    and bootstrap and none from an unselected package. The tree MUST have one
    top-level entry: the SDK registers a single instrumentation module per
    process and would otherwise load only one of several catalogs.
    """
    data = manifest(root, selection)
    temporary = Path(tempfile.mkdtemp(prefix=f".{output.name}.", dir=output.parent))
    try:
        for item in arr(field(data, "files"), "files"):
            record = obj(item, "selected file")
            source = root / string(field(record, "path"), "source path")
            relative = source.relative_to(root / "antithesis/test")
            destination = temporary / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)
        for item in arr(field(data, "runtime_dependencies"), "runtime dependencies"):
            record = obj(item, "runtime dependency")
            source = root / string(field(record, "path"), "runtime source")
            relative = source.relative_to(root / "antithesis/workload")
            destination = temporary / STAGED_CATALOG / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)
        atomic_json(temporary / "command-manifest.json", data)
        backup = output.with_name(f".{output.name}.previous")
        if backup.exists():
            shutil.rmtree(backup)
        if output.exists():
            os.replace(output, backup)
        os.replace(temporary, output)
        if backup.exists():
            shutil.rmtree(backup)
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)
    return data


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("inspect", "stage", "materialize"))
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument(
        "--selection",
        type=Path,
        default=Path(__file__).resolve().parent / "selections/control-core.json",
    )
    parser.add_argument(
        "--output", type=Path, default=Path(__file__).resolve().parents[1] / "build/selected-test"
    )
    parser.add_argument("--engine", choices=("podman", "docker"), default="podman")
    args = parser.parse_args()
    root = args.root.resolve()
    selection = read_selection(args.selection)
    if args.operation == "stage":
        data = stage(root, selection, args.output)
    elif args.operation == "materialize":
        data = materialization(
            root, selection, args.engine, root / "antithesis/runtime/configs" / selection.name
        )
    else:
        data = manifest(root, selection)
    print(json.dumps(data, sort_keys=True, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
