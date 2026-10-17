#!/usr/bin/env bash
set -euo pipefail
umask 077
trap 'printf "PostgreSQL bootstrap failed at line %s\n" "$LINENO" >&2' ERR

# The credential volume survives container restarts with the database volume.
# Its certificate authority is disposable and exists only during first boot.
secrets=/run/overalls-secrets
oracle=/run/overalls-oracle
data=${PGDATA:?PGDATA must be set}
[[ "$data" == /var/lib/postgresql/18/docker ]] || {
  echo 'unexpected PostgreSQL data path' >&2
  exit 1
}
aux=/var/lib/postgresql/antithesis-runtime
mkdir -p "$secrets" "$oracle" "$data" "$aux"
chmod 0700 "$secrets" "$oracle"
chown postgres:postgres /var/lib/postgresql
chmod 0700 /var/lib/postgresql
chown postgres:postgres "$(dirname "$data")"
chmod 0755 "$(dirname "$data")"
chown postgres:postgres "$data"
chmod 0700 "$data"

if [[ ! -f "$secrets/db-password" ]]; then
  if [[ -f "$data/PG_VERSION" ]]; then
    echo 'database credentials missing for retained PostgreSQL data' >&2
    exit 1
  fi
  openssl rand -hex 32 > "$secrets/oracle-password"
  openssl rand -hex 64 > "$secrets/secret-key-base"
  openssl rand -hex 32 > "$secrets/token-signing-secret"
  key=$(openssl rand -base64 32)
  printf '[{"id":"bootstrap","key":"%s"}]\n' "$key" > "$secrets/cloak-keys.json"
  unset key

  openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 14 \
    -subj /CN=overalls-antithesis-ca \
    -addext 'basicConstraints=critical,CA:TRUE' \
    -addext 'keyUsage=critical,keyCertSign,cRLSign' \
    -keyout "$secrets/.ca.key" -out "$secrets/ca.crt" >/dev/null 2>&1
  for name in pg marshall-a marshall-b; do
    openssl req -new -newkey rsa:3072 -nodes -sha256 \
      -subj "/CN=$name" \
      -keyout "$secrets/$name.key" -out "$secrets/.$name.csr" >/dev/null 2>&1
    printf 'subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\n' "$name" > "$secrets/.$name.ext"
    openssl x509 -req -in "$secrets/.$name.csr" \
      -CA "$secrets/ca.crt" -CAkey "$secrets/.ca.key" -CAcreateserial \
      -out "$secrets/$name.crt" -days 14 -sha256 \
      -extfile "$secrets/.$name.ext" >/dev/null 2>&1
    rm -f "$secrets/.$name.csr" "$secrets/.$name.ext"
  done
  rm -f "$secrets/.ca.key" "$secrets/ca.srl"
  # Publish the database password last. Its presence marks a complete
  # credential set; interruption before this point may regenerate it safely.
  openssl rand -hex 32 > "$secrets/.db-password.new"
  mv "$secrets/.db-password.new" "$secrets/db-password"
fi

for file in db-password oracle-password secret-key-base token-signing-secret cloak-keys.json ca.crt pg.key pg.crt marshall-a.key marshall-a.crt marshall-b.key marshall-b.crt; do
  [[ -s "$secrets/$file" ]] || { echo 'incomplete synthetic credential volume' >&2; exit 1; }
done
cp "$secrets/ca.crt" "$oracle/ca.crt"
cp "$secrets/oracle-password" "$oracle/oracle-password"
chmod 0600 "$oracle/ca.crt" "$oracle/oracle-password"

mkdir -p "$aux/tls"
cp "$secrets/pg.crt" "$aux/tls/pg.crt"
cp "$secrets/pg.key" "$aux/tls/pg.key"
cat > "$aux/tls/pg_hba.conf" <<'HBA'
local all all trust
hostssl all all 0.0.0.0/0 scram-sha-256
hostssl all all ::0/0 scram-sha-256
hostnossl all all 0.0.0.0/0 reject
hostnossl all all ::0/0 reject
HBA
cp "$secrets/db-password" "$aux/pg-password"
cp "$secrets/oracle-password" "$aux/oracle-password"
chown -R postgres:postgres "$aux"
chmod 0700 "$aux" "$aux/tls"
chmod 0600 "$aux/tls/pg.key" "$aux/pg-password" "$aux/oracle-password"
export ANTITHESIS_PG_AUX="$aux"
pgbin=/opt/overalls/postgresql/bin
as_postgres() {
  setpriv --reuid=postgres --regid=postgres --clear-groups "$@"
}

# @cc [owner:ghuntley,label:security;recovery] nix-postgres-initialization
# The source-built PostgreSQL 18 server MUST initialize only an empty private
# PGDATA, keep its fixed UID and durable cluster across restarts, and create the
# oracle role using the generated runtime password without argument exposure.
if [[ -f "$data/PG_VERSION" ]]; then
  [[ "$(<"$data/PG_VERSION")" == 18 ]] || {
    echo 'retained PostgreSQL data has an incompatible major version' >&2
    exit 1
  }
  [[ -f "$data/.overalls-initialized" ]] || {
    echo 'retained PostgreSQL bootstrap is incomplete' >&2
    exit 1
  }
else
  [[ -z "$(ls -A "$data")" ]] || {
    echo 'uninitialized PostgreSQL data directory is not empty' >&2
    exit 1
  }
  as_postgres "$pgbin/initdb" -D "$data" \
    --username=overalls --pwfile="$aux/pg-password" \
    --auth-local=trust --auth-host=scram-sha-256 \
    --locale=C --encoding=UTF8 --no-instructions >/dev/null
  as_postgres "$pgbin/pg_ctl" -D "$data" \
    -l "$aux/bootstrap.log" \
    -o "-c listen_addresses='' -c unix_socket_directories=$aux -c hba_file=$aux/tls/pg_hba.conf" \
    -w start >/dev/null
  cleanup_bootstrap() {
    as_postgres "$pgbin/pg_ctl" -D "$data" -m immediate -w stop >/dev/null || true
  }
  trap cleanup_bootstrap EXIT
  as_postgres "$pgbin/createdb" -h "$aux" -U overalls overalls
  as_postgres env PGHOST="$aux" /opt/overalls/entrypoints/oracle-init.sh
  as_postgres "$pgbin/pg_ctl" -D "$data" -m fast -w stop >/dev/null
  as_postgres touch "$data/.overalls-initialized"
  trap - EXIT
fi

exec setpriv --reuid=postgres --regid=postgres --clear-groups "$pgbin/postgres" -D "$data" \
  -c listen_addresses='*' \
  -c "unix_socket_directories=$aux" \
  -c ssl=on \
  -c "ssl_cert_file=$aux/tls/pg.crt" \
  -c "ssl_key_file=$aux/tls/pg.key" \
  -c "hba_file=$aux/tls/pg_hba.conf" \
  -c ssl_min_protocol_version=TLSv1.2 \
  -c password_encryption=scram-sha-256
