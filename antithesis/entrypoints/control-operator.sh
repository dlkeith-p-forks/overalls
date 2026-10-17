#!/usr/bin/env bash
set -euo pipefail
umask 077

# The enrollment container is the only writer for the private Control
# credential volume. It accepts one fixed operator action over typed files.
secrets=/run/overalls-secrets
control=/run/overalls-control-secrets
channel=/run/overalls-control-requests
release=/opt/overalls/marshall/bin/marshall
mkdir -p "$control" "$channel/requests" "$channel/results"
mkdir -p "$channel/state"
chmod 0700 "$control" "$channel" "$channel/requests" "$channel/results" "$channel/state"
[[ -s "$secrets/lilly-a-credential.json" && -s /run/overalls-oracle/fixture.json ]] || {
  echo 'Control operator fixture unavailable' >&2
  exit 1
}
host_id=$(jq -er '.host_id | select(type == "string" and test("^[0-9a-f-]{36}$"))' "$secrets/lilly-a-credential.json")

if [[ ! -e "$control/lilly-a-credential.json" ]]; then
  cp "$secrets/lilly-a-credential.json" "$control/.lilly-a-credential.json.new"
  chmod 0600 "$control/.lilly-a-credential.json.new"
  mv "$control/.lilly-a-credential.json.new" "$control/lilly-a-credential.json"
fi
fixture="$control/fixture.json"
fixture_eval='Application.put_env(:marshall, :operator_mode, true); {:ok, _} = Application.ensure_all_started(:marshall); Code.require_file("/opt/overalls/operator/fixture.ex"); OverallsAntithesis.Fixture.main(System.argv())'
compute_eval='Application.put_env(:marshall, :operator_mode, true); {:ok, _} = Application.ensure_all_started(:marshall); Code.require_file("/opt/overalls/operator/fixture.ex"); Code.require_file("/opt/overalls/operator/compute.ex"); OverallsAntithesis.Compute.main(System.argv())'
terminal_eval='Application.put_env(:marshall, :operator_mode, true); {:ok, _} = Application.ensure_all_started(:marshall); Code.require_file("/opt/overalls/operator/fixture.ex"); Code.require_file("/opt/overalls/operator/terminal.ex"); OverallsAntithesis.Terminal.main(System.argv())'
integration_eval='Application.put_env(:marshall, :operator_mode, true); {:ok, _} = Application.ensure_all_started(:marshall); Code.require_file("/opt/overalls/operator/fixture.ex"); Code.require_file("/opt/overalls/operator/integrations.ex"); OverallsAntithesis.Integrations.main(System.argv())'
guest_witness_eval='Application.put_env(:marshall, :operator_mode, true); {:ok, _} = Application.ensure_all_started(:marshall); Code.require_file("/opt/overalls/operator/fixture.ex"); Code.require_file("/opt/overalls/operator/guest_witness.ex"); OverallsAntithesis.GuestWitness.main(System.argv())'
bootstrap_marker="$control/fixture-bootstrap.started"
if [[ ! -e "$fixture" ]]; then
  [[ ! -e "$bootstrap_marker" ]] || {
    echo 'Control operator fixture bootstrap outcome uncertain' >&2
    exit 1
  }
  ( set -C; : > "$bootstrap_marker" ) || {
    echo 'Control operator fixture bootstrap marker unavailable' >&2
    exit 1
  }
  sync -f "$bootstrap_marker" "$control"
fi
if ! "$release" eval "$fixture_eval" bootstrap "$fixture" /dev/null >/dev/null 2>&1; then
  echo 'Control operator fixture bootstrap failed' >&2
  exit 1
fi
[[ -s "$fixture" ]] || { echo 'Control operator fixture unavailable' >&2; exit 1; }

host_dir=/run/overalls-host-secrets
host_enabled=${OVERALLS_ANTITHESIS_HOST_ENROLL:-0}
inner_satellites_enabled=${OVERALLS_ANTITHESIS_INNER_SATELLITES:-0}
case "$host_enabled" in
  0) ;;
  1)
    [[ -d "$host_dir" && ! -L "$host_dir" ]] && mountpoint -q "$host_dir" &&
      [[ "$(stat -c '%u' "$host_dir")" == 0 ]] || {
      echo 'Host fixture volume unavailable' >&2
      exit 1
    }
    chmod 0700 "$host_dir"
    [[ "$(stat -c '%a:%u' "$host_dir")" == '700:0' ]] || {
      echo 'Host fixture volume unsafe' >&2
      exit 1
    }
    if [[ -e "$host_dir/ca.crt" ]]; then
      outer_ca_hash=$(sha256sum "$secrets/ca.crt")
      host_ca_hash=$(sha256sum "$host_dir/ca.crt")
      [[ "${outer_ca_hash%% *}" == "${host_ca_hash%% *}" ]] || {
        echo 'Host fixture CA mismatch' >&2
        exit 1
      }
    else
      cp "$secrets/ca.crt" "$host_dir/.ca.crt.new"
      chmod 0600 "$host_dir/.ca.crt.new"
      mv -T "$host_dir/.ca.crt.new" "$host_dir/ca.crt"
    fi
    ;;
  *) echo 'Invalid host fixture mode' >&2; exit 1 ;;
esac
case "$inner_satellites_enabled" in
  0) ;;
  1) [[ "$host_enabled" == 1 ]] || { echo 'Inner satellites require measured host enrollment' >&2; exit 1; } ;;
  *) echo 'Invalid inner satellite fixture mode' >&2; exit 1 ;;
esac
case "${OVERALLS_ANTITHESIS_SATELLITES:-0}" in
  0) ;;
  1) /opt/overalls/entrypoints/satellite-enroll.sh ;;
  *) echo 'Invalid satellite fixture mode' >&2; exit 1 ;;
esac
# @cc [owner:ghuntley,label:verification;security] stub-image-registration
# Only the admission-stub profile registers Lilly's published stub image, and
# only a version-4 manifest carrying the fixed stub boot marker, through
# Marshall's reviewed Images.register action. Marshall still validates the
# manifest and derives its identity; no admission row is written here.
stub_image_eval='Application.put_env(:marshall, :operator_mode, true); {:ok, _} = Application.ensure_all_started(:marshall); [path] = System.argv(); {:ok, _} = Marshall.Compute.Images.register(path |> File.read!() |> JSON.decode!(), "Antithesis admission stub (not bootable)")'
case "${OVERALLS_ANTITHESIS_STORAGE_STUB:-0}" in
  0) ;;
  1)
    stub_manifest="$secrets/lilly-a-stub-image.json"
    if [[ -L "$stub_manifest" || ! -f "$stub_manifest" ]] ||
        ! jq -e '
          type == "object" and .version == 4 and .architecture == "x86_64" and
          .boot_args == "console=ttyS0 overalls.antithesis.storage_stub=1" and
          .rootfs.bytes == 4096 and .workspace_source_version == null
        ' "$stub_manifest" >/dev/null 2>&1; then
      echo 'Stub image manifest unavailable' >&2
      exit 1
    fi
    "$release" eval "$stub_image_eval" "$stub_manifest" >/dev/null 2>&1 || {
      echo 'Stub image registration failed' >&2
      exit 1
    }
    ;;
  *) echo 'Invalid storage stub fixture mode' >&2; exit 1 ;;
esac
touch /tmp/enrollment-ready

# Optional inner host enrollment is a distinct one-shot action. The marker
# survives operator restarts; uncertain issuance is verified, never reissued.
host_verified=0
inner_satellites_verified=0
# @cc [owner:ghuntley,label:security;verification] measured-host-enrollment
# The optional lilly-host credential MUST be issued from the fixed measured
# enrollment request through Marshall's reviewed CLI. A durable started marker
# MUST prevent reissue after uncertain completion; host-fixture publication MUST
# follow credential verification and committed host/pool observation.
enroll_optional_host() {
  [[ "$host_enabled" == 1 ]] || return 0
  [[ "$host_verified" == 0 ]] || return 0
  local request="$host_dir/lilly-host-enrollment.json"
  local credential="$host_dir/lilly-host-credential.json"
  local marker="$channel/state/host-enrollment.started"
  local public="$host_dir/.lilly-host-public.json.new" host pool
  if [[ -e "$control/host-fixture.json" ]]; then
    [[ -s "$credential" && -s "$host_dir/lilly-host-pool-id" ]] || {
      echo 'Retained host fixture incomplete' >&2
      exit 1
    }
    "$release" eval 'Marshall.Operations.CLI.main()' verify "$credential" >/dev/null 2>&1 || {
      echo 'Retained host credential unavailable' >&2
      exit 1
    }
    jq -e --arg host "$(jq -er '.host_id' "$credential")" \
      --arg pool "$(<"$host_dir/lilly-host-pool-id")" \
      --arg fixture "$(jq -er '.fixture_id' /run/overalls-oracle/fixture.json)" \
      'type == "object" and (keys == ["fixture_id","host_id","name","pool_id","schema_version"]) and .schema_version == 1 and .fixture_id == $fixture and .name == "lilly-host" and .host_id == $host and .pool_id == $pool' \
      "$control/host-fixture.json" >/dev/null || {
      echo 'Retained host fixture mismatch' >&2
      exit 1
    }
    host_verified=1
    return 0
  fi
  [[ -s "$request" ]] || return 0
  if [[ -L "$request" || ! -f "$request" ]] ||
      [[ "$(stat -c '%a:%u:%h' "$request")" != '600:0:1' ]] ||
      ! jq -e '
        type == "object" and .version == 3 and .name == "lilly-host" and
        .architecture == "x86_64" and
        (.machine_id | type == "string" and test("^sha256:[0-9a-f]{64}$")) and
        (.pools | type == "array" and length == 1 and .[0].name == "antithesis-host" and .[0].storage.backend == "zfs")
      ' "$request" >/dev/null 2>&1; then
    echo 'Invalid host enrollment request' >&2
    exit 1
  fi
  if [[ ! -e "$credential" ]]; then
    [[ ! -e "$marker" ]] || { echo 'Host enrollment outcome uncertain' >&2; exit 1; }
    ( set -C; : > "$marker" ) || { echo 'Host enrollment marker unavailable' >&2; exit 1; }
    sync -f "$marker" "$channel/state"
    if ! "$release" eval 'Marshall.Operations.CLI.main()' enroll "$request" "$credential" >/dev/null 2>&1; then
      echo 'Host enrollment outcome uncertain' >&2
      exit 1
    fi
  fi
  if ! "$release" eval 'Marshall.Operations.CLI.main()' verify "$credential" >/dev/null 2>&1; then
    echo 'Host credential verification unavailable' >&2
    exit 1
  fi
  if ! "$release" eval 'Marshall.Operations.CLI.main()' show lilly-host > "$public" 2>/dev/null; then
    echo 'Host registration observation unavailable' >&2
    exit 1
  fi
  host=$(jq -er '
    select(.name == "lilly-host" and .architecture == "x86_64") |
    .host_id | select(type == "string" and test("^[0-9a-f-]{36}$"))
  ' "$public") || { echo 'Invalid host registration' >&2; exit 1; }
  pool=$(jq -er '
    .pools | select(type == "array" and length == 1) | .[0].id |
    select(type == "string" and test("^[0-9a-f-]{36}$"))
  ' "$public") || { echo 'Invalid host pool registration' >&2; exit 1; }
  [[ "$host" == "$(jq -er '.host_id' "$credential")" && "$host" != "$host_id" ]] || {
    echo 'Host credential identity mismatch' >&2
    exit 1
  }
  printf '%s\n' "$pool" > "$host_dir/.lilly-host-pool-id.new"
  chmod 0600 "$host_dir/.lilly-host-pool-id.new"
  mv -T "$host_dir/.lilly-host-pool-id.new" "$host_dir/lilly-host-pool-id"
  jq -n --arg host "$host" --arg pool "$pool" \
    --arg fixture "$(jq -er '.fixture_id' /run/overalls-oracle/fixture.json)" \
    '{schema_version:1,fixture_id:$fixture,host_id:$host,pool_id:$pool,name:"lilly-host"}' > "$control/.host-fixture.json.new"
  chmod 0600 "$control/.host-fixture.json.new"
  mv -T "$control/.host-fixture.json.new" "$control/host-fixture.json"
  rm -f "$public"
  host_verified=1
}

publish_refusal() {
  local request_id=$1 reason=$2 destination="$channel/results/$1.json" temporary
  temporary=$(mktemp "$channel/results/.$request_id.XXXXXXXX")
  jq -n --arg id "$request_id" --arg reason "$reason" \
    '{version:1,request_id:$id,status:"refused",reason:$reason}' > "$temporary"
  mv -T "$temporary" "$destination"
}

publish_uncertain() {
  local request_id=$1 destination="$channel/results/$1.json" temporary
  temporary=$(mktemp "$channel/results/.$request_id.XXXXXXXX")
  jq -n --arg id "$request_id" \
    '{version:1,request_id:$id,status:"uncertain",reason:"operator_outcome_unavailable"}' > "$temporary"
  mv -T "$temporary" "$destination"
}

# Postgrex binds uuid parameters as 16-byte binaries, so the textual host ID
# MUST be dumped first; a string parameter raises and hides every rotation.
current_epoch() {
  local expected=$1
  rm -f /tmp/control-epoch
  "$release" eval 'Application.put_env(:marshall, :operator_mode, true); {:ok, _} = Application.ensure_all_started(:marshall); [host] = System.argv(); [[epoch]] = Ecto.Adapters.SQL.query!(Marshall.Repo, "SELECT connection_epoch FROM compute_hosts WHERE id = $1", [Ecto.UUID.dump!(host)], log: false).rows; File.write!("/tmp/control-epoch", Integer.to_string(epoch))' "$expected" >/dev/null
  [[ -s /tmp/control-epoch ]] || return 1
  local epoch
  epoch=$(</tmp/control-epoch)
  [[ "$epoch" =~ ^[1-9][0-9]*$ ]] || return 1
  printf '%s' "$epoch"
}

process_rotate() {
  local request=$1 request_id=$2 result="$channel/results/$2.json"
  local credential="$control/$2.json" ttl epoch
  if [[ -e "$result" ]]; then
    rm -f "$request"
    return
  fi
  if [[ -L "$request" || ! -f "$request" ]] ||
      [[ "$(stat -c '%a:%u:%h' "$request")" != '600:0:1' ]]; then
    publish_refusal "$request_id" invalid_request_file
    rm -f "$request"
    return
  fi
  if ! jq -e --arg host "$host_id" --arg id "$request_id" \
      'type == "object" and (keys == ["expected_host_id","operation","request_id","ttl_seconds","version"]) and .version == 1 and .operation == "rotate_lilly" and .request_id == $id and .expected_host_id == $host and (.ttl_seconds | type == "number" and . == floor and . >= 60 and . <= 86400)' \
      "$request" >/dev/null; then
    publish_refusal "$request_id" invalid_request
    rm -f "$request"
    return
  fi
  ttl=$(jq -er '.ttl_seconds' "$request")
  if [[ ! -e "$credential" ]]; then
    if ! "$release" eval 'Marshall.Operations.CLI.main()' rotate "$host_id" "$ttl" "$credential" >/dev/null; then
      publish_uncertain "$request_id"
      rm -f "$request"
      return
    fi
  fi
  if ! "$release" eval 'Marshall.Operations.CLI.main()' verify "$credential" >/dev/null; then
    publish_uncertain "$request_id"
    rm -f "$request"
    return
  fi
  if ! epoch=$(current_epoch "$host_id"); then
    publish_uncertain "$request_id"
    rm -f "$request"
    return
  fi
  local temporary
  temporary=$(mktemp "$channel/results/.$request_id.XXXXXXXX")
  jq -n --arg id "$request_id" --arg credential "$credential" --argjson epoch "$epoch" \
    '{version:1,request_id:$id,status:"issued",credential_file:$credential,generation:$epoch}' > "$temporary"
  mv -T "$temporary" "$result"
  rm -f "$request"
}

process_fixture_action() {
  local request=$1 request_id=$2 operation=$3 result="$channel/results/$2.json"
  local marker="$channel/state/$2.started" temporary expected field
  if [[ -e "$marker" ]]; then
    publish_uncertain "$request_id"
    rm -f "$request"
    return
  fi
  ( set -C; : > "$marker" ) || {
    publish_uncertain "$request_id"
    rm -f "$request"
    return
  }
  sync -f "$marker" "$channel/state"
  temporary=$(mktemp "$channel/results/.$request_id.XXXXXXXX")
  case "$operation" in
    refresh_repository) expected=$(jq -er '.repository_id' "$fixture"); field=repository_id ;;
    demote_admin_b) expected=$(jq -er '.admin_b.id' "$fixture"); field=user_id ;;
  esac
  if ! "$release" eval "$fixture_eval" "$operation" "$fixture" "$temporary" >/dev/null 2>&1 ||
      ! jq -e --arg op "$operation" --arg field "$field" --arg expected "$expected" \
        'type == "object" and (keys == (["operation","status","version",$field] | sort)) and .version == 1 and .status == "applied" and .operation == $op and .[$field] == $expected' \
        "$temporary" >/dev/null; then
    rm -f "$temporary"
    publish_uncertain "$request_id"
    rm -f "$request"
    return
  fi
  jq --arg id "$request_id" '. + {request_id:$id}' "$temporary" > "$temporary.issued"
  chmod 0600 "$temporary.issued"
  mv -T "$temporary.issued" "$result"
  rm -f "$temporary" "$request"
}

validate_compute_request() {
  local request=$1 request_id=$2 operation=$3
  jq -e --arg id "$request_id" --arg op "$operation" '
    def uuid: type == "string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$");
    def actor: . == "admin_a" or . == "admin_b" or . == "target";
    def base: type == "object" and .version == 1 and .request_id == $id and .operation == $op and (.actor | actor);
    def exact($fields): (keys == ($fields | sort));
    base and (
      if $op == "compute.catalog" or $op == "compute.list" then
        exact(["actor","operation","request_id","version"])
      elif $op == "compute.provision" then
        (exact(["actor","disk_bytes","image_id","memory_bytes","operation","profile","request_id","request_key","vcpu","version"]) or
         exact(["actor","disk_bytes","image_id","memory_bytes","name","operation","profile","request_id","request_key","vcpu","version"])) and
        (.request_key | uuid) and (.image_id | type == "string" and test("^sha256:[0-9a-f]{64}$")) and
        (.profile | IN("standard","customer","oss","inception")) and
        (.vcpu | type == "number" and . == floor and . >= 1 and . <= 32) and
        (.memory_bytes | type == "number" and . == floor and . >= 536870912 and . <= 274877906944) and
        (.disk_bytes | type == "number" and . == floor and . >= 2147483648 and . <= 536870912000 and (. % 4096) == 0) and
        ((has("name") | not) or (.name | type == "string" and length >= 1 and length <= 63))
      elif $op == "compute.lifecycle" then
        exact(["actor","kind","operation","request_id","request_key","version","vm_id"]) and
        (.request_key | uuid) and (.vm_id | uuid) and (.kind | IN("start","stop","delete"))
      elif $op == "compute.get" or $op == "compute.list_access" then
        exact(["actor","operation","request_id","version","vm_id"]) and (.vm_id | uuid)
      elif $op == "compute.operation" then
        exact(["actor","operation","operation_id","request_id","version","vm_id"]) and
        (.vm_id | uuid) and (.operation_id | uuid)
      elif $op == "compute.set_access" then
        exact(["actor","operation","recipient","request_id","request_key","role","version","vm_id"]) and
        (.request_key | uuid) and (.vm_id | uuid) and
        (.recipient | actor) and (.role | IN("web","viewer","operator","manager","revoked"))
      else false end
    )' "$request" >/dev/null 2>&1
}

validate_terminal_request() {
  local request=$1 request_id=$2 operation=$3
  jq -e --arg id "$request_id" --arg op "$operation" '
    def uuid: type == "string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$");
    def actor: . == "admin_a" or . == "admin_b" or . == "target";
    type == "object" and .version == 1 and .request_id == $id and .operation == $op and
    (.actor | actor) and (
      if $op == "terminal.create" then
        (keys == ["actor","create_request_id","operation","request_id","version","vm_id"]) and
        (.create_request_id | uuid) and (.vm_id | uuid)
      elif $op == "terminal.get" then
        (keys == ["actor","create_request_id","operation","request_id","version"]) and
        (.create_request_id | uuid)
      elif $op == "terminal.ticket" or $op == "terminal.kill" then
        (keys == ["actor","operation","request_id","session_id","version"]) and
        (.session_id | uuid)
      else false end
    )' "$request" >/dev/null 2>&1
}

validate_integration_request() {
  local request=$1 request_id=$2 operation=$3
  jq -e --arg id "$request_id" --arg op "$operation" '
    def uuid: type == "string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$");
    type == "object" and .version == 1 and .request_id == $id and .operation == $op and (
      if $op == "integration.create" or $op == "integration.retarget" or $op == "integration.rotate" then
        keys == ["operation","request_id","version"]
      elif $op == "integration.attach" or $op == "integration.detach" then
        (keys == ["operation","request_id","version","vm_id"]) and (.vm_id | uuid)
      else false end
    )' "$request" >/dev/null 2>&1
}

validate_guest_witness_request() {
  local request=$1 request_id=$2 operation=$3
  jq -e --arg id "$request_id" --arg op "$operation" '
    def uuid: type == "string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$");
    def positive: type == "number" and . == floor and . >= 1 and . <= 9007199254740991;
    type == "object" and .version == 1 and .request_id == $id and .operation == $op and (
      if $op == "guest.identity" then
        keys == ["operation","request_id","version"]
      elif $op == "guest.witness" or $op == "guest.terminal_witness" then
        (.placement_id | uuid) and (.execution_epoch | positive) and (.generation | positive) and
        keys == ["execution_epoch","generation","operation","placement_id","request_id","version"]
      elif $op == "guest.terminal_input_stall" then
        (.placement_id | uuid) and (.execution_epoch | positive) and (.generation | positive) and
        (keys == ["execution_epoch","generation","operation","placement_id","request_id","session_id","version"]) and
        (.session_id | type == "string" and test("^[1-9][0-9]{0,18}$") and
          (length < 19 or . <= "9223372036854775807"))
      elif $op == "guest.crash" then
        (.placement_id | uuid) and (.execution_epoch | positive) and (.generation | positive) and
        (keys == ["execution_epoch","generation","operation","placement_id","qemu_pid","qemu_start_ticks","request_id","version"]) and
        (.qemu_pid | positive and . > 1) and (.qemu_start_ticks | positive)
      else false end
    )' "$request" >/dev/null 2>&1
}

validate_terminal_replay_arm_request() {
  local request=$1 request_id=$2
  jq -e --arg id "$request_id" '
    def uuid: type == "string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$");
    def positive: type == "number" and . == floor and . >= 1 and . <= 9007199254740991;
    type == "object" and
    (keys == ["channel","connection_epoch","connection_session_id","execution_epoch","generation","guest_session_id","host_id","operation","placement_id","request_id","terminal_session_id","version","vm_id"]) and
    .version == 1 and .operation == "terminal.replay_arm" and .request_id == $id and
    (.host_id | uuid) and (.connection_session_id | uuid) and
    (.terminal_session_id | uuid) and (.vm_id | uuid) and (.placement_id | uuid) and
    (.connection_epoch | positive) and (.execution_epoch | positive) and
    (.generation | positive) and (.channel | positive) and
    (.guest_session_id | type == "string" and test("^[1-9][0-9]{0,18}$") and
      (length < 19 or . <= "9223372036854775807"))
  ' "$request" >/dev/null 2>&1
}

validate_terminal_replay_receipt_request() {
  local request=$1 request_id=$2
  jq -e --arg id "$request_id" '
    def uuid: type == "string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$");
    type == "object" and
    (keys == ["arm_request_id","operation","request_id","version"]) and
    .version == 1 and .operation == "terminal.replay_receipt" and .request_id == $id and
    (.arm_request_id | uuid)
  ' "$request" >/dev/null 2>&1
}

process_domain_action() {
  local request=$1 request_id=$2 operation=$3 evaluation=$4 result="$channel/results/$2.json"
  local marker="$channel/state/$2.started" temporary
  if [[ -e "$marker" ]]; then
    publish_uncertain "$request_id"
    rm -f "$request"
    return
  fi
  ( set -C; : > "$marker" ) || {
    publish_uncertain "$request_id"
    rm -f "$request"
    return
  }
  sync -f "$marker" "$channel/state"
  temporary=$(mktemp "$channel/results/.$request_id.XXXXXXXX")
  if ! "$release" eval "$evaluation" "$operation" "$fixture" "$request" "$temporary" >/dev/null 2>&1 ||
      ! jq -e --arg id "$request_id" --arg op "$operation" \
        'type == "object" and .version == 1 and .request_id == $id and .operation == $op and ((.status == "ok" and (keys == ["operation","request_id","status","value","version"])) or ((.status == "error" or .status == "unavailable") and (keys == ["operation","reason","request_id","status","version"]) and (.reason | type == "string" and length >= 1 and length <= 100)))' \
        "$temporary" >/dev/null 2>&1; then
    rm -f "$temporary"
    publish_uncertain "$request_id"
    rm -f "$request"
    return
  fi
  mv -T "$temporary" "$result"
  rm -f "$request"
}

process_request() {
  local request=$1 request_id=$2 result="$channel/results/$2.json" operation
  if [[ -e "$result" ]]; then
    rm -f "$request"
    return
  fi
  if [[ -L "$request" || ! -f "$request" ]] ||
      [[ "$(stat -c '%a:%u:%h' "$request")" != '600:0:1' ]]; then
    publish_refusal "$request_id" invalid_request_file
    rm -f "$request"
    return
  fi
  operation=$(jq -er '.operation | select(type == "string")' "$request" 2>/dev/null) || operation=''
  case "$operation" in
    rotate_lilly)
      process_rotate "$request" "$request_id"
      ;;
    refresh_repository)
      if jq -e --arg id "$request_id" \
          --arg repository "$(jq -er '.repository_id' "$fixture")" \
          'type == "object" and (keys == ["expected_repository_id","operation","request_id","version"]) and .version == 1 and .operation == "refresh_repository" and .request_id == $id and .expected_repository_id == $repository' \
          "$request" >/dev/null; then
        process_fixture_action "$request" "$request_id" "$operation"
      else
        publish_refusal "$request_id" invalid_request
        rm -f "$request"
      fi
      ;;
    demote_admin_b)
      if jq -e --arg id "$request_id" \
          --arg user "$(jq -er '.admin_b.id' "$fixture")" \
          'type == "object" and (keys == ["expected_user_id","operation","request_id","version"]) and .version == 1 and .operation == "demote_admin_b" and .request_id == $id and .expected_user_id == $user' \
          "$request" >/dev/null; then
        process_fixture_action "$request" "$request_id" "$operation"
      else
        publish_refusal "$request_id" invalid_request
        rm -f "$request"
      fi
      ;;
    compute.catalog|compute.provision|compute.lifecycle|compute.get|compute.operation|compute.list|compute.set_access|compute.list_access)
      if validate_compute_request "$request" "$request_id" "$operation"; then
        process_domain_action "$request" "$request_id" "$operation" "$compute_eval"
      else
        publish_refusal "$request_id" invalid_request
        rm -f "$request"
      fi
      ;;
    terminal.create|terminal.get|terminal.ticket|terminal.kill)
      if validate_terminal_request "$request" "$request_id" "$operation"; then
        process_domain_action "$request" "$request_id" "$operation" "$terminal_eval"
      else
        publish_refusal "$request_id" invalid_request
        rm -f "$request"
      fi
      ;;
    integration.create|integration.retarget|integration.rotate|integration.attach|integration.detach)
      if validate_integration_request "$request" "$request_id" "$operation"; then
        process_domain_action "$request" "$request_id" "$operation" "$integration_eval"
      else
        publish_refusal "$request_id" invalid_request
        rm -f "$request"
      fi
      ;;
    guest.witness|guest.identity|guest.terminal_witness|guest.terminal_input_stall|guest.crash)
      if validate_guest_witness_request "$request" "$request_id" "$operation"; then
        process_domain_action "$request" "$request_id" "$operation" "$guest_witness_eval"
      else
        publish_refusal "$request_id" invalid_request
        rm -f "$request"
      fi
      ;;
    terminal.replay_arm)
      if validate_terminal_replay_arm_request "$request" "$request_id"; then
        process_domain_action "$request" "$request_id" "$operation" "$guest_witness_eval"
      else
        publish_refusal "$request_id" invalid_request
        rm -f "$request"
      fi
      ;;
    terminal.replay_receipt)
      if validate_terminal_replay_receipt_request "$request" "$request_id"; then
        process_domain_action "$request" "$request_id" "$operation" "$guest_witness_eval"
      else
        publish_refusal "$request_id" invalid_request
        rm -f "$request"
      fi
      ;;
    *)
      publish_refusal "$request_id" invalid_request
      rm -f "$request"
      ;;
  esac
}

while true; do
  enroll_optional_host
  # @cc [owner:ghuntley,label:security;verification] inner-satellites-after-host
  # Inner service credentials MUST be issued only after the measured host's
  # credential, committed pool and private fixture have been verified.
  if [[ "$inner_satellites_enabled" == 1 && "$host_verified" == 1 && "$inner_satellites_verified" == 0 ]]; then
    /opt/overalls/entrypoints/inner-satellite-enroll.sh
    inner_satellites_verified=1
  fi
  for request in "$channel"/requests/*.json; do
    [[ -e "$request" || -L "$request" ]] || continue
    name=${request##*/}
    request_id=${name%.json}
    [[ "$request_id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || {
      echo 'invalid Control request filename' >&2
      exit 1
    }
    process_request "$request" "$request_id"
  done
  sleep 1
done
