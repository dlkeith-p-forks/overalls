"""Private fixture identity and Enrico workload endpoints."""

import json
import os
from dataclasses import dataclass
from pathlib import Path
from uuid import UUID

from core.config import Config
from core.sql import SqlOracle
from repository.client import EnricoClient
from repository.fixture import GitOrigin
from repository.operator import RepositoryOperator
from repository.oracle import RepositoryOracle


@dataclass(frozen=True)
class RepositoryFixture:
    fixture_id: str
    repository_id: UUID
    registered_by_id: UUID
    owner: str
    name: str


@dataclass(frozen=True)
class Runtime:
    fixture: RepositoryFixture
    enrico: EnricoClient
    origin: GitOrigin
    oracle: RepositoryOracle
    operator: RepositoryOperator
    mirror_root: Path


def read_repository_fixture(path: Path) -> RepositoryFixture:
    """@cc [owner:ghuntley,label:verification] repository-issued-fixture
    The private manifest MUST carry a bounded fixture ID and fixed repository
    source with valid registration IDs. Bootstrap callers MUST compare that fixture ID
    to the independently issued control fixture before using the registration.
    """
    parsed: object = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(parsed, dict) or parsed.get("schema_version") != 1:
        raise ValueError("invalid repository fixture manifest")
    fixture_id = parsed.get("fixture_id")
    if not isinstance(fixture_id, str) or not 1 <= len(fixture_id) <= 128:
        raise ValueError("invalid repository fixture identity")
    owner, name, namespace = parsed.get("owner"), parsed.get("name"), parsed.get("namespace")
    if not isinstance(owner, str) or not isinstance(name, str) or namespace != "github":
        raise ValueError("invalid repository fixture source")
    if (owner, name) != ("Fixture", "demo"):
        raise ValueError("unexpected repository fixture source")
    repository_id, registered_by_id = parsed.get("repository_id"), parsed.get("registered_by_id")
    if not isinstance(repository_id, str) or not isinstance(registered_by_id, str):
        raise ValueError("invalid repository fixture identity")
    return RepositoryFixture(fixture_id, UUID(repository_id), UUID(registered_by_id), owner, name)


def load_runtime() -> Runtime:
    config = Config.from_environment()
    fixture = read_repository_fixture(
        Path(
            os.getenv(
                "ANTITHESIS_REPOSITORY_FIXTURE_FILE", "/run/overalls-control-secrets/fixture.json"
            )
        )
    )
    mirror_root = Path(os.environ["ANTITHESIS_ENRICO_MIRROR_ROOT"])
    return Runtime(
        fixture=fixture,
        enrico=EnricoClient(
            os.environ["ANTITHESIS_ENRICO_URL"],
            Path(os.environ["ANTITHESIS_ENRICO_CA_FILE"]),
            Path(os.environ["ANTITHESIS_ENRICO_TOKEN_FILE"]),
        ),
        origin=GitOrigin(
            os.environ["ANTITHESIS_ORIGIN_ADMIN_URL"],
            Path(os.environ["ANTITHESIS_ORIGIN_ADMIN_TOKEN_FILE"]),
        ),
        oracle=RepositoryOracle(SqlOracle(config), mirror_root),
        operator=RepositoryOperator(Path(os.environ["ANTITHESIS_CONTROL_REQUEST_DIR"])),
        mirror_root=mirror_root,
    )
