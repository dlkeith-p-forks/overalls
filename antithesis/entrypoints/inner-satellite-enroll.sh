#!/usr/bin/env bash
set -euo pipefail
umask 077

# @cc [owner:ghuntley,label:security;recovery] inner-host-satellite-issuance
# This optional operator action MUST issue Ziggy and Galileo credentials only
# for the verified measured inner Lilly host. It MUST mark each first attempt
# durably before calling Marshall; absent output after an uncertain attempt
# MUST fail closed rather than rotate authority again. Existing output MUST be
# verified against the same host before reuse. Rotation MUST follow a fresh,
# measured execution-ready report and reviewed host enablement. Provider keys
# stay private.
[[ "${MARSHALL_INSTANCE_ID:-}" == enrollment-operator && "${OVERALLS_ANTITHESIS_INNER_SATELLITES:-0}" == 1 ]] || exit 1

host_dir=/run/overalls-host-secrets
control=/run/overalls-control-secrets
outer=/run/overalls-secrets
oracle=/run/overalls-oracle/fixture.json
release=/opt/overalls/marshall/bin/marshall
[[ -d "$host_dir" && -d "$control" ]] || {
  echo 'Inner satellite private volume unavailable' >&2
  exit 1
}
[[ "$(stat -c '%a:%u' "$host_dir")" == '700:0' ]] || {
  echo 'Inner satellite private volume unsafe' >&2
  exit 1
}

private_file() {
  [[ -s "$1" && -f "$1" && ! -L "$1" && "$(stat -c '%a:%u:%h' "$1")" == '600:0:1' ]]
}

credential="$host_dir/lilly-host-credential.json"
pool_file="$host_dir/lilly-host-pool-id"
fixture="$control/host-fixture.json"
enrollment="$host_dir/lilly-host-enrollment.json"
private_file "$credential" && private_file "$pool_file" && private_file "$fixture" &&
  private_file "$enrollment" && private_file "$oracle" &&
  private_file "$outer/lilly-a-credential.json" || {
  echo 'Verified measured host fixture unavailable' >&2
  exit 1
}
"$release" eval 'Marshall.Operations.CLI.main()' verify "$credential" >/dev/null 2>&1 || {
  echo 'Inner host credential verification failed' >&2
  exit 1
}

host=$(jq -er '.host_id | select(type == "string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"))' "$credential")
pool=$(<"$pool_file")
[[ "$pool" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || exit 1
outer_host=$(jq -er '.host_id | select(type == "string")' "$outer/lilly-a-credential.json")
fixture_id=$(jq -er '.fixture_id | select(type == "string" and test("^[0-9a-f]{32}$"))' "$oracle")
[[ "$host" != "$outer_host" ]] || {
  echo 'Inner host credential reused outer identity' >&2
  exit 1
}
jq -e --arg host "$host" --arg pool "$pool" --arg fixture "$fixture_id" \
  'type == "object" and (keys == ["fixture_id","host_id","name","pool_id","schema_version"]) and
   .schema_version == 1 and .name == "lilly-host" and .host_id == $host and .pool_id == $pool and
   .fixture_id == $fixture' \
  "$fixture" >/dev/null || {
  echo 'Inner host fixture identity mismatch' >&2
  exit 1
}
rm -f "$host_dir/inner-satellites-ready"

# The inner monitor writes the same native ZFS/control sample to this private
# share as it publishes to the observation share. Lilly's ready bit is true
# only after an authenticated v4 report has actually been delivered.
health="$host_dir/lilly-host-health.json"
zpool=$(jq -er '.pools | select(type == "array" and length == 1) | .[0].storage.zpool_guid | select(type == "string" and test("^[1-9][0-9]{0,19}$"))' "$enrollment")
dataset=$(jq -er '.pools | select(type == "array" and length == 1) | .[0].storage.dataset_guid | select(type == "string" and test("^[1-9][0-9]{0,19}$"))' "$enrollment")
deadline=$(($(date +%s) + 600))
while true; do
  now=$(date +%s)
  if [[ "$now" -gt "$deadline" ]]; then
    echo 'Measured inner host readiness unavailable' >&2
    exit 1
  fi
  if private_file "$health"; then
    modified=$(stat -c %Y "$health")
    if [[ "$modified" -le "$now" && $((now - modified)) -le 10 ]] &&
      jq -e --arg zpool "$zpool" --arg dataset "$dataset" \
        'type == "object" and .version == 1 and .connected == true and
         .execution_ready == true and .zpool_guid == $zpool and
         .dataset_guid == $dataset and
         (.sampled_at_ns | type == "number" and . > 0)' \
        "$health" >/dev/null 2>&1; then
      break
    fi
  fi
  sleep 2
done

public=$("$release" eval 'Marshall.Operations.CLI.main()' show lilly-host 2>/dev/null) || {
  echo 'Inner host public authority unavailable' >&2
  exit 1
}
jq -e --arg host "$host" \
  'type == "object" and .host_id == $host and .name == "lilly-host" and
   .maintenance_mode == "normal" and (.enabled | type == "boolean")' \
  <<< "$public" >/dev/null || {
  echo 'Inner host public authority mismatch' >&2
  exit 1
}
if ! jq -e '.enabled == true' <<< "$public" >/dev/null; then
  enable_marker="$host_dir/.inner-host-enable.started"
  [[ ! -e "$enable_marker" ]] || {
    echo 'Inner host enablement outcome uncertain' >&2
    exit 1
  }
  ( set -C; : > "$enable_marker" ) || {
    echo 'Inner host enablement marker unavailable' >&2
    exit 1
  }
  sync -f "$enable_marker" "$host_dir"
  if ! "$release" eval 'Marshall.Operations.CLI.main()' enable "$host" >/dev/null 2>&1; then
    echo 'Inner host enablement outcome uncertain' >&2
    exit 1
  fi
  public=$("$release" eval 'Marshall.Operations.CLI.main()' show lilly-host 2>/dev/null) || {
    echo 'Inner host enablement verification unavailable' >&2
    exit 1
  }
  jq -e --arg host "$host" \
    'type == "object" and .host_id == $host and .enabled == true and
     .maintenance_mode == "normal"' <<< "$public" >/dev/null || {
    echo 'Inner host enablement unverified' >&2
    exit 1
  }
fi

issue_role() {
  local role=$1 path="$host_dir/inner-$1.token" marker="$host_dir/.inner-$1.started"
  local verification
  if [[ ! -e "$path" ]]; then
    [[ ! -e "$marker" ]] || {
      echo 'Inner satellite credential issuance uncertain' >&2
      exit 1
    }
    ( set -C; : > "$marker" ) || {
      echo 'Inner satellite issuance marker unavailable' >&2
      exit 1
    }
    sync -f "$marker" "$host_dir"
    if ! "$release" eval 'Marshall.Operations.CLI.main()' "$role-rotate" "$host" 86400 "$path" >/dev/null 2>&1; then
      echo 'Inner satellite credential outcome uncertain' >&2
      exit 1
    fi
  fi
  private_file "$path" || {
    echo 'Inner satellite credential file unsafe' >&2
    exit 1
  }
  verification=$("$release" eval 'Marshall.Operations.CLI.main()' "$role-verify" "$path" 2>/dev/null) || {
    echo 'Inner satellite credential verification failed' >&2
    exit 1
  }
  jq -e --arg host "$host" \
    'type == "object" and .verified == true and .host_id == $host and
     (.credential_id | type == "string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"))' \
    <<< "$verification" >/dev/null || {
    echo 'Inner satellite credential host mismatch' >&2
    exit 1
  }
}

issue_role ziggy
issue_role galileo

provider_key() {
  local role=$1 path="$host_dir/inner-$1.key" temporary
  if [[ ! -e "$path" ]]; then
    temporary=$(mktemp "$host_dir/.inner-$role.key.XXXXXXXX")
    openssl rand -hex 32 > "$temporary"
    chmod 0600 "$temporary"
    sync -f "$temporary"
    mv -T "$temporary" "$path"
    sync -f "$host_dir"
  fi
  private_file "$path" && [[ "$(wc -c < "$path")" == 65 ]] &&
    grep -Eq '^[0-9a-f]{64}$' "$path" || {
    echo 'Inner synthetic provider key unavailable' >&2
    exit 1
  }
}

provider_key openai
provider_key anthropic

touch "$host_dir/inner-satellites-ready"
sync -f "$host_dir/inner-satellites-ready" "$host_dir"
