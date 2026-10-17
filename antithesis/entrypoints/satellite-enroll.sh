#!/usr/bin/env bash
set -euo pipefail
umask 077

# @cc [owner:ghuntley,label:security;verification] satellite-enrollment-custody
# Only the enrollment operator may issue these exact host-bound service tokens.
# Existing output is verified, never rotated automatically after uncertain issuance.
# The three synthetic trust domains remain separate: Marshall, private Audi, origin.
secrets=/run/overalls-secrets
satellite=/run/overalls-satellite-secrets
public=/run/overalls-satellite-public
release=/opt/kittens/marshall/bin/marshall
[[ "${MARSHALL_INSTANCE_ID:-}" == enrollment-operator && -d "$satellite" && -d "$public" ]] || exit 1
for role in ziggy galileo audi porsche; do
  [[ -d "/run/overalls-satellite-$role" ]] || exit 1
done
[[ -s "$secrets/lilly-a-credential.json" && -s "$secrets/ca.crt" ]] || exit 1
host=$(jq -er '.host_id | select(type == "string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"))' "$secrets/lilly-a-credential.json")
chmod 0700 "$satellite"
private_file() {
  [[ -s "$1" && -f "$1" && ! -L "$1" && "$(stat -c '%a:%u:%h' "$1")" == '600:0:1' ]]
}

operator() {
  "$release" eval 'Marshall.Operations.CLI.main()' "$@" >/dev/null 2>&1
}

issue_host_token() {
  local name=$1 rotate=$2 verify=$3 path="$satellite/$1.token"
  if [[ ! -e "$path" ]]; then
    [[ ! -e "$satellite/.$name.started" ]] || { echo 'Satellite credential issuance uncertain' >&2; exit 1; }
    ( set -C; : > "$satellite/.$name.started" )
    sync -f "$satellite/.$name.started" "$satellite"
    if ! operator "$rotate" "$host" 86400 "$path"; then
      echo 'Satellite credential outcome uncertain' >&2
      exit 1
    fi
  fi
  private_file "$path" || exit 1
  operator "$verify" "$path" || { echo 'Satellite credential verification failed' >&2; exit 1; }
}

issue_host_token ziggy ziggy-rotate ziggy-verify
issue_host_token galileo galileo-rotate galileo-verify

audi="$satellite/audi-gateway.token"
if [[ ! -e "$audi" ]]; then
  [[ ! -e "$satellite/.audi-gateway.started" ]] || { echo 'Audi credential issuance uncertain' >&2; exit 1; }
  ( set -C; : > "$satellite/.audi-gateway.started" )
  sync -f "$satellite/.audi-gateway.started" "$satellite"
  operator audi-gateway-rotate antithesis-audi "$host" '10.87.0.23' "$audi" || {
    echo 'Audi credential outcome uncertain' >&2
    exit 1
  }
fi
private_file "$audi" || exit 1
operator audi-gateway-verify "$audi" || { echo 'Audi credential verification failed' >&2; exit 1; }

porsche="$satellite/porsche.token"
if [[ ! -e "$porsche" ]]; then
  operator gateway-prepare "$porsche" || { echo 'Porsche token preparation uncertain' >&2; exit 1; }
fi
private_file "$porsche" || exit 1
"$release" eval 'Application.put_env(:marshall, :operator_mode, true); {:ok, _} = Application.ensure_all_started(:marshall); [name, path] = System.argv(); {:ok, %{enabled: true}} = Marshall.Operations.SSHGateway.ensure(name, path)' antithesis-porsche "$porsche" >/dev/null 2>&1 || {
  echo 'Porsche credential verification failed' >&2
  exit 1
}

if [[ ! -e "$satellite/host-id" ]]; then
  printf '%s\n' "$host" > "$satellite/.host-id.new"
  chmod 0600 "$satellite/.host-id.new"
  mv -T "$satellite/.host-id.new" "$satellite/host-id"
fi
[[ "$(<"$satellite/host-id")" == "$host" ]] || { echo 'Satellite host binding mismatch' >&2; exit 1; }
private_file "$satellite/host-id" || exit 1
if [[ ! -e "$satellite/control-ca.pem" ]]; then
  cp "$secrets/ca.crt" "$satellite/.control-ca.pem.new"
  chmod 0600 "$satellite/.control-ca.pem.new"
  mv -T "$satellite/.control-ca.pem.new" "$satellite/control-ca.pem"
fi
cmp -s "$secrets/ca.crt" "$satellite/control-ca.pem" || { echo 'Satellite control CA mismatch' >&2; exit 1; }
private_file "$satellite/control-ca.pem" || exit 1

if [[ ! -e "$satellite/openai.key" ]]; then
  openssl rand -hex 32 > "$satellite/.openai.key.new"
  chmod 0600 "$satellite/.openai.key.new"
  mv -T "$satellite/.openai.key.new" "$satellite/openai.key"
fi
private_file "$satellite/openai.key" || exit 1
if [[ ! -e "$satellite/anthropic.key" ]]; then
  openssl rand -hex 32 > "$satellite/.anthropic.key.new"
  chmod 0600 "$satellite/.anthropic.key.new"
  mv -T "$satellite/.anthropic.key.new" "$satellite/anthropic.key"
fi
private_file "$satellite/anthropic.key" || exit 1

# This root signs only the synthetic private Audi listener. It never signs the
# independent upstream origin or Marshall control certificates.
if [[ ! -e "$satellite/private-root.pem" ]]; then
  [[ ! -e "$satellite/private-leaf.pem" && ! -e "$satellite/private-leaf.key" ]] || exit 1
  issuer=$(mktemp -d)
  chmod 0700 "$issuer"
  trap 'rm -rf -- "$issuer"' EXIT
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 30 \
    -subj /CN=Overalls-Antithesis-Private-Root \
    -addext 'basicConstraints=critical,CA:TRUE' \
    -addext 'keyUsage=critical,keyCertSign,cRLSign' \
    -keyout "$issuer/private-root.key" -out "$issuer/private-root.pem" >/dev/null 2>&1
  openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -subj /CN=llm.internal \
    -keyout "$issuer/private-leaf.key" -out "$issuer/private-leaf.csr" >/dev/null 2>&1
  printf 'subjectAltName=DNS:llm.internal,DNS:*.integration.internal\nextendedKeyUsage=serverAuth\n' > "$issuer/private-leaf.ext"
  openssl x509 -req -in "$issuer/private-leaf.csr" \
    -CA "$issuer/private-root.pem" -CAkey "$issuer/private-root.key" -CAcreateserial \
    -days 30 -extfile "$issuer/private-leaf.ext" -out "$issuer/private-leaf.pem" >/dev/null 2>&1
  cp "$issuer/private-root.pem" "$satellite/private-root.pem"
  cp "$issuer/private-leaf.pem" "$satellite/private-leaf.pem"
  cp "$issuer/private-leaf.key" "$satellite/private-leaf.key"
  chmod 0600 "$satellite/private-leaf.key" "$satellite/private-root.pem" "$satellite/private-leaf.pem"
fi
for file in private-root.pem private-leaf.pem private-leaf.key; do
  private_file "$satellite/$file" || exit 1
done
openssl verify -CAfile "$satellite/private-root.pem" -verify_hostname llm.internal "$satellite/private-leaf.pem" >/dev/null 2>&1 || exit 1
openssl verify -CAfile "$satellite/private-root.pem" -verify_hostname example.integration.internal "$satellite/private-leaf.pem" >/dev/null 2>&1 || exit 1

if [[ ! -e "$public/private-root.pem" ]]; then
  cp "$satellite/private-root.pem" "$public/.private-root.pem.new"
  chmod 0644 "$public/.private-root.pem.new"
  mv -T "$public/.private-root.pem.new" "$public/private-root.pem"
fi
cmp -s "$satellite/private-root.pem" "$public/private-root.pem" || exit 1

publish_role() {
  local role=$1 directory="/run/overalls-satellite-$1" file
  shift
  chmod 0700 "$directory"
  for file in host-id control-ca.pem "$@"; do
    if [[ ! -e "$directory/$file" ]]; then
      cp "$satellite/$file" "$directory/.$file.new"
      chmod 0600 "$directory/.$file.new"
      mv -T "$directory/.$file.new" "$directory/$file"
    fi
    private_file "$directory/$file" && cmp -s "$satellite/$file" "$directory/$file" || exit 1
  done
  touch "$directory/issued-ready"
}

publish_role ziggy ziggy.token openai.key anthropic.key
publish_role galileo galileo.token
publish_role audi private-root.pem private-leaf.pem private-leaf.key
publish_role porsche porsche.token
touch "$satellite/issued-ready"
