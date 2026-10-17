"""Durable local attempt ledger; this module never submits remote runs."""

from __future__ import annotations

import argparse
import json
import re
import uuid
from pathlib import Path

from identity import freeze, sha256
from schema import (
    EvidenceError,
    Json,
    arr,
    atomic_json,
    field,
    integer,
    locked,
    narrow_json,
    obj,
    read_json,
    string,
)

PURPOSES = frozenset({"bootstrap", "baseline", "mutant", "retry", "resweep"})
ACTIVE = frozenset({"reserved", "submitted"})
MAX_ACTIVE_ATTEMPTS = 5
CANONICAL_LEDGER = "antithesis/runtime/campaign-ledger.json"
HASH = re.compile(r"^[0-9a-f]{64}$")
DURATION_MINUTES = {
    "bootstrap": 15,
    "baseline": 60,
    "mutant": 15,
    "retry": 15,
    "resweep": 15,
}


def policy_duration(purpose: str) -> int:
    try:
        return DURATION_MINUTES[purpose]
    except KeyError as exc:
        raise EvidenceError(f"unsupported attempt purpose {purpose}") from exc


def duration(value: int | None, name: str, *, required: bool = True) -> int | None:
    if value is None:
        if required:
            raise EvidenceError(f"{name} is required")
        return None
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise EvidenceError(f"{name} must be a positive integer number of minutes")
    return value


def reserved_duration(item: dict[str, Json]) -> int:
    purpose = string(field(item, "purpose"), "attempt purpose")
    expected = policy_duration(purpose)
    recorded = integer(field(item, "requested_duration_minutes"), "reserved duration")
    if recorded != expected:
        raise EvidenceError("reserved duration differs from campaign policy")
    return expected


def verify_manifest(path: Path, root: Path, check_current: bool = True) -> dict[str, Json]:
    manifest = obj(read_json(path), "build identity")
    identity = string(field(manifest, "identity_sha256"), "identity_sha256")
    payload: dict[str, Json] = {
        key: value for key, value in manifest.items() if key != "identity_sha256"
    }
    if (
        sha256(
            json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
        )
        != identity
    ):
        raise EvidenceError("build identity payload hash mismatch")
    if check_current:
        compose = root / string(field(manifest, "selected_compose"), "selected_compose")
        # Requery source, Nix derivations/closures and immutable local image IDs.
        current = freeze(
            root,
            compose,
            string(field(manifest, "engine"), "engine"),
            string(field(manifest, "selection"), "selection"),
        )
        if current["identity_sha256"] != identity:
            raise EvidenceError("build inputs or image identity changed; freeze a new baseline")
    return manifest


def safety_messages(manifest: dict[str, Json]) -> list[str]:
    roster = obj(field(manifest, "assertion_roster"), "assertion_roster")
    messages = {
        string(field(obj(entry, "property"), "message"), "property message")
        for entry in arr(field(roster, "catalog_properties"), "catalog_properties")
        if string(field(obj(entry, "property"), "primary_kind"), "primary_kind")
        in {"always", "always_or_unreachable", "unreachable"}
    }
    messages.update(
        string(item, "authored safety message")
        for item in arr(field(roster, "authored_safety_messages"), "authored_safety_messages")
    )
    if not messages:
        raise EvidenceError("empty safety roster")
    return sorted(messages)


def initialize(
    old: Json | None,
    identity: str,
    messages: list[str],
    config: str = "control-core",
    *,
    authored_messages: list[str] | None = None,
    harness_scope: str | None = None,
    mutation: dict[str, Json] | None = None,
) -> dict[str, Json]:
    authored = messages if authored_messages is None else authored_messages
    scope = identity if harness_scope is None else harness_scope
    if not messages or len(messages) != len(set(messages)):
        raise EvidenceError("safety roster must be nonempty and unique")
    if len(authored) != len(set(authored)) or not set(authored).issubset(messages):
        raise EvidenceError("authored safety messages must be unique members of the roster")
    if not scope:
        raise EvidenceError("missing harness scope identity")
    if old is None:
        if mutation is not None:
            raise EvidenceError("mutant cannot initialize without a green baseline lineage")
        return obj(
            narrow_json(
                {
                    "format": 2,
                    "configurations": {
                        config: {
                            "identity_sha256": identity,
                            "safety_messages": messages,
                            "authored_safety_messages": authored,
                            "harness_scope_sha256": scope,
                            "green_baseline": None,
                            "baseline_run_id": None,
                            "mutation": None,
                        }
                    },
                    "safety_messages": messages,
                    "safety_count": len(messages),
                    "ceiling": 5 * len(messages),
                    "attempts": [],
                }
            ),
            "campaign ledger",
        )
    ledger = obj(old, "campaign ledger")
    if integer(field(ledger, "format"), "ledger format") != 2:
        raise EvidenceError(
            "unsupported campaign ledger format; preserve and migrate spent attempts"
        )
    configurations = obj(field(ledger, "configurations"), "configurations")
    attempts = arr(field(ledger, "attempts"), "attempts")
    previous = obj(configurations[config], "configuration") if config in configurations else None
    if (
        previous is not None
        and previous.get("identity_sha256") == identity
        and previous.get("safety_messages") == messages
        and previous.get("authored_safety_messages") == authored
        and previous.get("harness_scope_sha256") == scope
    ):
        if mutation is not None and previous.get("mutation") != mutation:
            raise EvidenceError("mutation receipt differs from initialized artifact")
        return ledger
    if previous is not None and any(
        obj(item, "attempt").get("config") == config
        and string(field(obj(item, "attempt"), "status"), "status") in ACTIVE
        for item in attempts
    ):
        raise EvidenceError("cannot change configuration identity with an in-flight attempt")
    updated: dict[str, Json] = {
        "identity_sha256": identity,
        "safety_messages": narrow_json(messages),
        "authored_safety_messages": narrow_json(authored),
        "harness_scope_sha256": scope,
        "green_baseline": None,
        "baseline_run_id": None,
        "mutation": None,
    }
    if mutation is not None:
        if previous is None:
            raise EvidenceError("mutant requires an initialized baseline configuration")
        baseline = previous.get("green_baseline")
        if not isinstance(baseline, str) or previous.get("harness_scope_sha256") != scope:
            raise EvidenceError("mutant requires matching green baseline and harness scope")
        if (
            set(mutation)
            != {
                "format",
                "baseline_identity_sha256",
                "mutant_identity_sha256",
                "harness_scope_sha256",
                "property_message",
                "patch_sha256",
            }
            or mutation.get("format") != 1
        ):
            raise EvidenceError("invalid mutant patch receipt")
        target = string(field(mutation, "property_message"), "mutant target")
        patch = string(field(mutation, "patch_sha256"), "patch hash")
        if (
            mutation.get("baseline_identity_sha256") != baseline
            or mutation.get("mutant_identity_sha256") != identity
            or mutation.get("harness_scope_sha256") != scope
            or target not in authored
            or HASH.fullmatch(patch) is None
        ):
            raise EvidenceError("mutant patch receipt differs from baseline or frozen artifact")
        updated["green_baseline"] = baseline
        updated["baseline_run_id"] = previous.get("baseline_run_id")
        updated["mutation"] = narrow_json(mutation)
    union = set(messages)
    for name, value in configurations.items():
        if name == config:
            continue
        other = obj(value, "configuration")
        union.update(
            string(item, "safety message")
            for item in arr(field(other, "safety_messages"), "safety_messages")
        )
    if len(attempts) > 5 * len(union):
        raise EvidenceError("new safety roster lowers ceiling below spent attempts")
    configurations[config] = updated
    ledger["safety_messages"] = narrow_json(sorted(union))
    ledger["safety_count"] = len(union)
    ledger["ceiling"] = 5 * len(union)
    return ledger


def configuration(ledger: dict[str, Json], config: str, identity: str) -> dict[str, Json]:
    configurations = obj(field(ledger, "configurations"), "configurations")
    if config not in configurations:
        raise EvidenceError("initialize this Compose config before reserving attempts")
    selected = obj(configurations[config], "configuration")
    if string(field(selected, "identity_sha256"), "configuration identity") != identity:
        raise EvidenceError("campaign identity differs from build manifest")
    return selected


def reserve(
    ledger: dict[str, Json],
    identity: str,
    purpose: str,
    property_message: str | None,
    config: str = "control-core",
    requested_duration_minutes: int | None = None,
    *,
    duration_minutes: int | None = None,
) -> dict[str, Json]:
    """@cc [owner:ghuntley,label:verification] remote-attempt-admission
    Every remote attempt MUST consume one durable slot before submission,
    including bootstrap/retries. At most five may remain active, mutant
    selection MUST serialize, and a mutant requires a matching green baseline.
    At most one baseline for a Compose config may be reserved or submitted;
    refusing another baseline MUST preserve the current baseline lineage.
    Each purpose MUST use its exact campaign duration (baseline 60 minutes;
    bootstrap, mutant, retry and resweep 15 minutes), recorded at reservation.
    """
    if purpose not in PURPOSES:
        raise EvidenceError(f"unsupported attempt purpose {purpose}")
    if (
        requested_duration_minutes is not None
        and duration_minutes is not None
        and requested_duration_minutes != duration_minutes
    ):
        raise EvidenceError("conflicting requested duration values")
    requested_duration = (
        requested_duration_minutes if requested_duration_minutes is not None else duration_minutes
    )
    expected_duration = policy_duration(purpose)
    if requested_duration is None:
        requested_duration = expected_duration
    elif duration(requested_duration, "requested duration") != expected_duration:
        raise EvidenceError(
            f"{purpose} attempts require an exact duration of {expected_duration} minutes"
        )
    selected = configuration(ledger, config, identity)
    attempts = arr(field(ledger, "attempts"), "attempts")
    ceiling = integer(field(ledger, "ceiling"), "ceiling")
    if len(attempts) >= ceiling:
        raise EvidenceError(f"remote attempt ceiling reached ({ceiling})")
    active = [
        obj(item, "attempt")
        for item in attempts
        if string(field(obj(item, "attempt"), "status"), "status") in ACTIVE
    ]
    if len(active) >= MAX_ACTIVE_ATTEMPTS:
        raise EvidenceError("five remote attempts already in flight")
    if purpose == "baseline" and any(
        item.get("config") == config and item.get("purpose") == "baseline" for item in active
    ):
        raise EvidenceError("baseline already reserved or submitted for this Compose config")
    if purpose in {"mutant", "retry", "resweep"}:
        baseline = selected.get("green_baseline")
        if not isinstance(baseline, str):
            raise EvidenceError("matching immutable green baseline lineage required")
        if property_message is None or property_message not in arr(
            field(selected, "authored_safety_messages"), "authored_safety_messages"
        ):
            raise EvidenceError(
                "mutant target must have an authored safety callsite in this profile"
            )
        mutation = obj(field(selected, "mutation"), "mutant patch receipt")
        if (
            mutation.get("property_message") != property_message
            or mutation.get("mutant_identity_sha256") != identity
            or mutation.get("baseline_identity_sha256") != baseline
        ):
            raise EvidenceError("mutant target or exact artifact differs from patch receipt")
        if any(
            item.get("purpose") in {"mutant", "retry", "resweep"}
            and item.get("status") == "reserved"
            for item in active
        ):
            raise EvidenceError("mutant selection/submission already reserved")
    elif property_message is not None:
        raise EvidenceError("only mutant attempts may name a property")
    if purpose == "baseline" and selected.get("mutation") is not None:
        raise EvidenceError("mutant artifact cannot establish a baseline lineage")
    item: dict[str, Json] = {
        "attempt_id": uuid.uuid4().hex,
        "config": config,
        "identity_sha256": identity,
        "purpose": purpose,
        "requested_duration_minutes": requested_duration,
        "submitted_duration_minutes": None,
        "observed_duration_minutes": None,
        "property_message": property_message,
        "status": "reserved",
        "run_id": None,
        "result": None,
        "receipt_sha256": None,
        "execution_scope": None,
        "baseline_identity_sha256": selected.get("green_baseline")
        if purpose in {"mutant", "retry", "resweep"}
        else None,
        "patch_sha256": obj(field(selected, "mutation"), "mutation").get("patch_sha256")
        if purpose in {"mutant", "retry", "resweep"}
        else None,
    }
    attempts.append(item)
    if purpose == "baseline":
        selected["green_baseline"] = None
        selected["baseline_run_id"] = None
    return item


def transition(
    ledger: dict[str, Json],
    attempt_id: str,
    action: str,
    run_id: str | None = None,
    result: str | None = None,
    receipt: dict[str, Json] | None = None,
    duration_minutes: int | None = None,
    *,
    requested_duration_minutes: int | None = None,
    observed_duration_minutes: int | None = None,
) -> dict[str, Json]:
    """@cc [owner:ghuntley,label:verification] remote-attempt-duration
    Submitted and completed transitions MUST carry explicit duration evidence
    matching the reserved policy duration; missing or mismatched evidence MUST
    be refused, and completed attempts MUST retain the observed duration.
    """
    if action not in {"submitted", "completed"} and any(
        value is not None
        for value in (duration_minutes, requested_duration_minutes, observed_duration_minutes)
    ):
        raise EvidenceError(f"duration evidence is not accepted for {action} transitions")
    attempts = arr(field(ledger, "attempts"), "attempts")
    matches = [
        obj(item, "attempt")
        for item in attempts
        if obj(item, "attempt").get("attempt_id") == attempt_id
    ]
    if len(matches) != 1:
        raise EvidenceError("unknown or duplicate attempt ID")
    item = matches[0]
    status = string(field(item, "status"), "status")
    if action == "submitted":
        if status != "reserved" or not run_id:
            raise EvidenceError("submitted requires a reserved attempt and run ID")
        if observed_duration_minutes is not None:
            raise EvidenceError("observed duration is only accepted when completing an attempt")
        if (
            requested_duration_minutes is not None
            and duration_minutes is not None
            and requested_duration_minutes != duration_minutes
        ):
            raise EvidenceError("conflicting submitted duration values")
        submitted_duration = (
            requested_duration_minutes
            if requested_duration_minutes is not None
            else duration_minutes
        )
        if submitted_duration is None:
            raise EvidenceError("submitted duration is required")
        expected_duration = reserved_duration(item)
        if duration(submitted_duration, "submitted duration") != expected_duration:
            raise EvidenceError("submitted duration differs from reserved duration")
        if any(obj(other, "attempt").get("run_id") == run_id for other in attempts):
            raise EvidenceError("duplicate remote run ID")
        item["status"] = "submitted"
        item["run_id"] = run_id
        item["submitted_duration_minutes"] = submitted_duration
    elif action == "completed":
        if status != "submitted" or result not in {"green", "red", "unknown"}:
            raise EvidenceError("completion requires a submitted attempt and explicit result")
        if requested_duration_minutes is not None:
            raise EvidenceError("requested duration is only accepted when submitting an attempt")
        if (
            observed_duration_minutes is not None
            and duration_minutes is not None
            and observed_duration_minutes != duration_minutes
        ):
            raise EvidenceError("conflicting observed duration values")
        observed_duration = (
            observed_duration_minutes if observed_duration_minutes is not None else duration_minutes
        )
        if observed_duration is None:
            raise EvidenceError("observed duration is required")
        expected_duration = reserved_duration(item)
        submitted_duration = integer(
            field(item, "submitted_duration_minutes"), "submitted duration"
        )
        if submitted_duration != expected_duration:
            raise EvidenceError("submitted duration differs from reserved duration")
        if duration(observed_duration, "observed duration") != expected_duration:
            raise EvidenceError("observed duration differs from reserved duration")
        if result == "green":
            if receipt is None:
                raise EvidenceError("green result requires a triage receipt")
            if set(receipt) != {
                "format",
                "run_id",
                "identity_sha256",
                "result",
                "setup_complete",
                "execution_scope",
            }:
                raise EvidenceError("triage receipt contains missing or unexpected fields")
            if integer(field(receipt, "format"), "receipt format") != 1:
                raise EvidenceError("unsupported baseline receipt")
            if string(field(receipt, "run_id"), "receipt run_id") != item["run_id"]:
                raise EvidenceError("baseline receipt run ID mismatch")
            if (
                string(field(receipt, "identity_sha256"), "receipt identity")
                != item["identity_sha256"]
            ):
                raise EvidenceError("baseline receipt build identity mismatch")
            if string(field(receipt, "result"), "receipt result") != "green":
                raise EvidenceError("baseline receipt must be green")
            if field(receipt, "setup_complete") is not True:
                raise EvidenceError("baseline receipt lacks setup completion")
            string(field(receipt, "execution_scope"), "receipt execution_scope")
        item["status"] = "completed"
        item["result"] = result
        item["observed_duration_minutes"] = observed_duration
        if receipt is not None:
            item["receipt_sha256"] = sha256(
                json.dumps(
                    receipt, sort_keys=True, separators=(",", ":"), ensure_ascii=False
                ).encode()
            )
            item["execution_scope"] = field(receipt, "execution_scope")
        configs = obj(field(ledger, "configurations"), "configurations")
        selected = obj(configs[string(field(item, "config"), "attempt config")], "configuration")
        if item.get("purpose") == "baseline" and selected.get("identity_sha256") == item.get(
            "identity_sha256"
        ):
            selected["green_baseline"] = item["identity_sha256"] if result == "green" else None
            selected["baseline_run_id"] = item["run_id"] if result == "green" else None
    elif action == "abandoned":
        if status != "reserved":
            raise EvidenceError("only a never-submitted reservation may be abandoned")
        item["status"] = "abandoned"
        item["result"] = "unknown"
    else:
        raise EvidenceError(f"unknown transition {action}")
    return item


def modify(
    path: Path,
    operation: str,
    identity: str,
    messages: list[str],
    *,
    purpose: str | None = None,
    property_message: str | None = None,
    attempt_id: str | None = None,
    run_id: str | None = None,
    result: str | None = None,
    receipt: dict[str, Json] | None = None,
    duration_minutes: int | None = None,
    requested_duration_minutes: int | None = None,
    observed_duration_minutes: int | None = None,
    config: str = "control-core",
    authored_messages: list[str] | None = None,
    harness_scope: str | None = None,
    mutation: dict[str, Json] | None = None,
) -> dict[str, Json]:
    if operation not in {"reserve", "submitted", "completed"} and any(
        value is not None
        for value in (duration_minutes, requested_duration_minutes, observed_duration_minutes)
    ):
        raise EvidenceError(f"duration evidence is not accepted for {operation}")
    if operation == "reserve" and observed_duration_minutes is not None:
        raise EvidenceError("observed duration is only accepted when completing an attempt")
    with locked(path):
        old = read_json(path) if path.exists() else None
        if operation == "init":
            ledger = initialize(
                old,
                identity,
                messages,
                config,
                authored_messages=authored_messages,
                harness_scope=harness_scope,
                mutation=mutation,
            )
            outcome = ledger
        else:
            if old is None:
                raise EvidenceError("initialize campaign before reserving attempts")
            ledger = obj(old, "campaign ledger")
            if operation == "completed":
                # A submitted attempt is bound to the identity it was reserved
                # under; later source drift must not strand its concurrency slot.
                if config not in obj(field(ledger, "configurations"), "configurations"):
                    raise EvidenceError("initialize this Compose config before reserving attempts")
            else:
                configuration(ledger, config, identity)
            if operation == "reserve":
                outcome = reserve(
                    ledger,
                    identity,
                    purpose or "",
                    property_message,
                    config,
                    requested_duration_minutes,
                    duration_minutes=duration_minutes,
                )
            else:
                attempts = arr(field(ledger, "attempts"), "attempts")
                if not any(
                    obj(item, "attempt").get("attempt_id") == attempt_id
                    and obj(item, "attempt").get("config") == config
                    for item in attempts
                ):
                    raise EvidenceError("attempt does not belong to selected Compose config")
                outcome = transition(
                    ledger,
                    attempt_id or "",
                    operation,
                    run_id,
                    result,
                    receipt,
                    duration_minutes,
                    requested_duration_minutes=requested_duration_minutes,
                    observed_duration_minutes=observed_duration_minutes,
                )
        atomic_json(path, ledger)
        return outcome


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "operation", choices=("init", "reserve", "submitted", "completed", "abandoned", "status")
    )
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--identity", type=Path, required=True)
    parser.add_argument("--ledger", type=Path, help=f"must be {CANONICAL_LEDGER}")
    parser.add_argument("--purpose", choices=sorted(PURPOSES))
    parser.add_argument("--property-message")
    parser.add_argument("--attempt-id")
    parser.add_argument("--run-id")
    parser.add_argument("--result", choices=("green", "red", "unknown"))
    parser.add_argument(
        "--duration-minutes",
        "--duration",
        dest="duration_minutes",
        type=int,
        help="exact policy duration for reserve, submission or completion",
    )
    parser.add_argument("--requested-duration-minutes", dest="requested_duration_minutes", type=int)
    parser.add_argument("--observed-duration-minutes", dest="observed_duration_minutes", type=int)
    parser.add_argument("--mutation-receipt", type=Path)
    parser.add_argument("--patch", type=Path, help="exact reviewed patch bytes for mutant init")
    parser.add_argument(
        "--receipt", type=Path, help="triage receipt required for every green result"
    )
    args = parser.parse_args()
    if args.operation not in {"reserve", "submitted", "completed"} and any(
        value is not None
        for value in (
            args.duration_minutes,
            args.requested_duration_minutes,
            args.observed_duration_minutes,
        )
    ):
        raise EvidenceError(f"duration evidence is not accepted for {args.operation}")
    if args.operation == "reserve" and args.observed_duration_minutes is not None:
        raise EvidenceError("observed duration is only accepted when completing an attempt")
    root = args.root.resolve()
    ledger_path = root / CANONICAL_LEDGER
    if args.ledger is not None and args.ledger.resolve() != ledger_path:
        raise EvidenceError(f"all configurations must use the global ledger {ledger_path}")
    if args.operation == "init" and not ledger_path.exists():
        legacy = sorted(ledger_path.parent.glob("*-ledger.json"))
        if legacy:
            raise EvidenceError("legacy per-config ledgers require reviewed attempt migration")
    manifest = verify_manifest(args.identity, root)
    identity = string(field(manifest, "identity_sha256"), "identity_sha256")
    messages = safety_messages(manifest)
    roster = obj(field(manifest, "assertion_roster"), "assertion roster")
    authored_messages = sorted(
        string(item, "authored safety message")
        for item in arr(field(roster, "authored_safety_messages"), "authored_safety_messages")
    )
    harness_scope = string(field(manifest, "harness_scope_sha256"), "harness scope")
    if (args.mutation_receipt is None) != (args.patch is None):
        raise EvidenceError("mutant initialization requires both patch and patch receipt")
    if args.mutation_receipt is not None and args.operation != "init":
        raise EvidenceError("mutant patch receipt is accepted only during initialization")
    mutation = (
        obj(read_json(args.mutation_receipt), "mutant patch receipt")
        if args.mutation_receipt
        else None
    )
    if mutation is not None and sha256(args.patch.read_bytes()) != field(mutation, "patch_sha256"):
        raise EvidenceError("mutant patch bytes differ from patch receipt")
    config = string(field(manifest, "selection"), "selection")
    if args.operation == "status":
        outcome = obj(read_json(ledger_path), "campaign ledger")
        configuration(outcome, config, identity)
    else:
        outcome = modify(
            ledger_path,
            args.operation,
            identity,
            messages,
            purpose=args.purpose,
            property_message=args.property_message,
            attempt_id=args.attempt_id,
            run_id=args.run_id,
            result=args.result,
            receipt=obj(read_json(args.receipt), "triage receipt") if args.receipt else None,
            duration_minutes=args.duration_minutes,
            requested_duration_minutes=args.requested_duration_minutes,
            observed_duration_minutes=args.observed_duration_minutes,
            config=config,
            authored_messages=authored_messages,
            harness_scope=harness_scope,
            mutation=mutation,
        )
    print(json.dumps(outcome, sort_keys=True, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
