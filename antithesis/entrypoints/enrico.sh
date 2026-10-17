#!/usr/bin/env bash
set -euo pipefail
umask 077

# This container owns exactly one Enrico release child. The only supported
# control action stops that child and starts the same immutable release again.
state=/var/lib/enrico
secrets=/run/overalls-enrico-secrets
client=/run/overalls-enrico-client
channel=/run/overalls-enrico-control
runtime=/run/enrico
release=/opt/overalls/enrico/bin/enrico
mkdir -p "$state" "$secrets" "$client" "$channel/requests" "$channel/results" "$runtime"
chmod 0700 "$state" "$secrets" "$client" "$channel" "$channel/requests" "$channel/results" "$runtime"
for slot in {0..7}; do
  lock="$state/.enrico-git-slot-$slot.lock"
  if [[ ! -e "$lock" && ! -L "$lock" ]]; then
    : > "$lock"
  fi
  [[ -f "$lock" && ! -L "$lock" ]] &&
    [[ "$(stat -c '%a:%u:%h' "$lock")" == '600:0:1' ]] || {
      echo 'invalid Enrico slot lock file' >&2
      exit 1
    }
done

if [[ ! -f "$secrets/ready" ]]; then
  if [[ -e "$state/launch-generation" ]]; then
    echo 'Enrico credentials missing for retained state' >&2
    exit 1
  fi
  rm -f "$secrets"/{ca.pem,server.pem,server.key,token,.ca.key,.server.csr,.server.ext}
  openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 30 \
    -subj /CN=overalls-antithesis-enrico-ca \
    -addext 'basicConstraints=critical,CA:TRUE' \
    -addext 'keyUsage=critical,keyCertSign,cRLSign' \
    -keyout "$secrets/.ca.key" -out "$secrets/ca.pem" >/dev/null 2>&1
  openssl req -new -newkey rsa:3072 -nodes -sha256 \
    -subj /CN=enrico.fleet.internal \
    -keyout "$secrets/server.key" -out "$secrets/.server.csr" >/dev/null 2>&1
  printf 'subjectAltName=DNS:enrico.fleet.internal\nextendedKeyUsage=serverAuth\n' > "$secrets/.server.ext"
  openssl x509 -req -in "$secrets/.server.csr" \
    -CA "$secrets/ca.pem" -CAkey "$secrets/.ca.key" -CAcreateserial \
    -out "$secrets/server.pem" -days 30 -sha256 \
    -extfile "$secrets/.server.ext" >/dev/null 2>&1
  rm -f "$secrets/.ca.key" "$secrets/.server.csr" "$secrets/.server.ext" "$secrets/ca.srl"
  printf '%s' "$(openssl rand -hex 32)" > "$secrets/token"
  touch "$secrets/ready"
fi
for file in ca.pem server.pem server.key token; do
  [[ -s "$secrets/$file" ]] || { echo 'Enrico runtime credential unavailable' >&2; exit 1; }
done
[[ -s /run/overalls-origin-ca/ca.pem ]] || { echo 'origin trust root unavailable' >&2; exit 1; }
cp "$secrets/ca.pem" "$client/ca.pem"
cp "$secrets/token" "$client/token"
chmod 0600 "$client/ca.pem" "$client/token"
jq -n '{bind:"10.87.0.20",port:5445,state_dir:"/var/lib/enrico",token_file:"/run/overalls-enrico-secrets/token",certificate_file:"/run/overalls-enrico-secrets/server.pem",key_file:"/run/overalls-enrico-secrets/server.key",status_socket:"/run/enrico/status.sock"}' > "$runtime/config.json"
chmod 0600 "$runtime/config.json"
export ENRICO_CONFIG_FILE="$runtime/config.json" GIT_SSL_CAINFO=/run/overalls-origin-ca/ca.pem
export RELEASE_DISTRIBUTION=none ERL_CRASH_DUMP=/dev/null
export RELEASE_COOKIE="$(openssl rand -hex 32)"

child=0
generation=0
if [[ -s "$state/launch-generation" ]]; then
  generation=$(<"$state/launch-generation")
  [[ "$generation" =~ ^[1-9][0-9]*$ ]] || { echo 'invalid Enrico launch generation' >&2; exit 1; }
fi

healthy() {
  curl --silent --show-error --fail --unix-socket "$runtime/status.sock" \
    http://enrico/health/ready 2>/dev/null |
    jq -e '.version == 1 and .ready == true and .role == "enrico"' >/dev/null
}

wait_healthy() {
  local attempt
  for ((attempt=0; attempt<120; attempt++)); do
    kill -0 "$child" 2>/dev/null || return 1
    healthy && return 0
    sleep 0.25
  done
  return 1
}

persist_generation() {
  local next=$1
  printf '%s\n' "$next" > "$state/.launch-generation.new"
  chmod 0600 "$state/.launch-generation.new"
  mv -T "$state/.launch-generation.new" "$state/launch-generation"
  sync -f "$state"
  generation=$next
}

launch() {
  rm -f "$runtime/status.sock"
  "$release" start &
  child=$!
  wait_healthy || return 1
  persist_generation "$((generation + 1))"
}

publish() {
  local request_id=$1 status=$2 reason=$3 before_pid=$4 after_pid=$5 before_generation=$6
  local result="$channel/results/$request_id.json" temporary
  temporary=$(mktemp "$channel/results/.$request_id.XXXXXXXX")
  if [[ "$status" == restarted ]]; then
    jq -n --arg id "$request_id" --argjson old_pid "$before_pid" \
      --argjson new_pid "$after_pid" --argjson old_gen "$before_generation" \
      --argjson new_gen "$generation" \
      '{version:1,request_id:$id,status:"restarted",previous_pid:$old_pid,current_pid:$new_pid,previous_generation:$old_gen,generation:$new_gen}' > "$temporary"
  else
    jq -n --arg id "$request_id" --arg status "$status" --arg reason "$reason" \
      '{version:1,request_id:$id,status:$status,reason:$reason}' > "$temporary"
  fi
  mv -T "$temporary" "$result"
}

stop_child() {
  local attempt
  kill -TERM "$child" 2>/dev/null || return 1
  for ((attempt=0; attempt<60; attempt++)); do
    if ! kill -0 "$child" 2>/dev/null || [[ "$(ps -o stat= -p "$child" 2>/dev/null)" == Z* ]]; then
      wait "$child" || true
      return 0
    fi
    sleep 0.25
  done
  return 1
}

terminate() {
  trap - TERM INT
  if ((child > 0)); then kill -TERM "$child" 2>/dev/null || true; wait "$child" || true; fi
  exit 0
}
trap terminate TERM INT

launch || { echo 'Enrico release readiness unavailable' >&2; exit 1; }
if [[ -s "$state/restart-inflight" ]]; then
  interrupted=$(<"$state/restart-inflight")
  if [[ "$interrupted" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
    [[ -e "$channel/results/$interrupted.json" ]] ||
      publish "$interrupted" uncertain operator_outcome_unavailable 0 0 0
    rm -f "$channel/requests/$interrupted.json"
  fi
  rm -f "$state/restart-inflight"
fi

while true; do
  kill -0 "$child" 2>/dev/null || { echo 'Enrico release exited' >&2; exit 1; }
  /opt/overalls/entrypoints/observe-enrico.sh || true
  for request in "$channel"/requests/*.json; do
    [[ -e "$request" || -L "$request" ]] || continue
    name=${request##*/}
    request_id=${name%.json}
    [[ "$request_id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || { echo 'invalid Enrico request filename' >&2; exit 1; }
    if [[ -e "$channel/results/$request_id.json" ]]; then rm -f "$request"; continue; fi
    if [[ -L "$request" || ! -f "$request" ]] ||
       [[ "$(stat -c '%a:%u:%h' "$request")" != '600:0:1' ]] ||
       ! jq -e --arg id "$request_id" \
         'type == "object" and (keys == ["operation","request_id","version"]) and .version == 1 and .operation == "restart_enrico" and .request_id == $id' "$request" >/dev/null; then
      publish "$request_id" refused invalid_request 0 0 0
      rm -f "$request"
      continue
    fi
    before_pid=$child
    before_generation=$generation
    printf '%s\n' "$request_id" > "$state/restart-inflight"
    chmod 0600 "$state/restart-inflight"
    sync -f "$state"
    if ! stop_child; then
      publish "$request_id" uncertain stop_unconfirmed 0 0 0
      rm -f "$request" "$state/restart-inflight"
      exit 1
    fi
    if ! launch; then
      publish "$request_id" uncertain start_unconfirmed 0 0 0
      rm -f "$request" "$state/restart-inflight"
      exit 1
    fi
    if ((child == before_pid)); then
      publish "$request_id" uncertain pid_reused 0 0 0
    else
      /opt/overalls/entrypoints/observe-enrico.sh || true
      publish "$request_id" restarted '' "$before_pid" "$child" "$before_generation"
    fi
    rm -f "$request" "$state/restart-inflight"
  done
  sleep 1
done
