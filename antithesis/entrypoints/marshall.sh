#!/usr/bin/env bash
set -euo pipefail
umask 077

mode=${1:-}
case "$mode" in serve|migrate|enroll) ;; *) echo 'invalid Marshall entrypoint mode' >&2; exit 2 ;; esac

secrets=/run/overalls-secrets
release=/opt/overalls/marshall/bin/marshall
for file in db-password secret-key-base token-signing-secret cloak-keys.json ca.crt; do
  [[ -s "$secrets/$file" ]] || { echo 'Marshall startup credentials unavailable' >&2; exit 1; }
done
password=$(<"$secrets/db-password")
[[ "$password" =~ ^[0-9a-f]{64}$ ]] || { echo 'invalid synthetic database credential' >&2; exit 1; }
export DATABASE_URL="postgres://overalls:${password}@pg:5432/overalls"
unset password
export MARSHALL_DB_TLS=verify MARSHALL_DB_CA_CERTFILE="$secrets/ca.crt"
export SECRET_KEY_BASE="$(<"$secrets/secret-key-base")"
export TOKEN_SIGNING_SECRET="$(<"$secrets/token-signing-secret")"
export MARSHALL_CLOAK_KEYS="$(<"$secrets/cloak-keys.json")"
# Synthetic SSH host CA trust, shaped like nix/domains/system/marshall.nix;
# runtime.exs replaces management_host with PHX_HOST.
export MARSHALL_SSH_HOST_CA_KEY_FILE="$secrets/ssh-host-ca"
MARSHALL_SSH_HOST_TRUST=$(jq -cn --arg ca "$(cut -d' ' -f1,2 "$secrets/ssh-host-ca.pub")" \
  '{version:1,ca:$ca,management_host:"marshall-a",zone:"apps.antithesis.test",retirement:2421446400}')
export MARSHALL_SSH_HOST_TRUST
export MARSHALL_REPLICA_COUNT=2 POOL_SIZE=5 MARSHALL_DB_CONNECTION_BUDGET=40
export MARSHALL_MAIL_TRANSPORT=local_relay MARSHALL_SMTP_HOST=127.0.0.1
export MARSHALL_SMTP_PORT=2525 MARSHALL_MAIL_FROM=antithesis@example.invalid
export PHX_HOST=marshall-a RELEASE_DISTRIBUTION=none ERL_CRASH_DUMP=/dev/null
export RELEASE_COOKIE="$(openssl rand -hex 32)"

case "$mode" in
  migrate)
    export MARSHALL_INSTANCE_ID=migration PHX_SERVER=false
    unset PORT MARSHALL_TLS_CERTFILE MARSHALL_TLS_KEYFILE
    rm -f /tmp/migrations-ready
    "$release" eval 'Marshall.Vault.keyring!(System.fetch_env!("MARSHALL_CLOAK_KEYS")); Marshall.Operations.Migrate.main()'
    "$release" eval 'Application.load(:marshall); {:ok, _} = Application.ensure_all_started(:ecto_sql); {:ok, _} = Application.ensure_all_started(:postgrex); {:ok, _, _} = Ecto.Migrator.with_repo(Marshall.Repo, fn repo -> for sql <- ["GRANT USAGE ON SCHEMA public TO overalls_oracle", "GRANT SELECT ON ALL TABLES IN SCHEMA public TO overalls_oracle", "ALTER DEFAULT PRIVILEGES FOR ROLE overalls IN SCHEMA public GRANT SELECT ON TABLES TO overalls_oracle"] do Ecto.Adapters.SQL.query!(repo, sql, [], log: false) end end, pool_size: 2)'
    touch /tmp/migrations-ready
    exec sleep infinity
    ;;
  serve)
    case "${MARSHALL_INSTANCE_ID:-}" in marshall-a|marshall-b) ;; *) echo 'invalid Marshall instance' >&2; exit 2 ;; esac
    if [[ "${MARSHALL_ANTITHESIS_SMTP:-}" == fixture ]]; then
      smtp_password_file=/run/overalls-smtp-credentials/smtp-password
      smtp_ca_file=/run/overalls-smtp-ca/ca.pem
      [[ -s "$smtp_password_file" && -s "$smtp_ca_file" ]] || {
        echo 'synthetic SMTP credentials unavailable' >&2
        exit 1
      }
      export MARSHALL_MAIL_TRANSPORT=smtp MARSHALL_SMTP_HOST=smtp.fixture.test
      export MARSHALL_SMTP_PORT=465 MARSHALL_SMTP_TLS=implicit
      export MARSHALL_SMTP_USERNAME=fixture MARSHALL_SMTP_CA_CERTFILE="$smtp_ca_file"
      export MARSHALL_SMTP_PASSWORD="$(<"$smtp_password_file")"
    fi
    export PHX_SERVER=true MARSHALL_BIND_IP=0.0.0.0 MARSHALL_TLS_PORT=443
    case "$MARSHALL_INSTANCE_ID" in
      marshall-a) export MARSHALL_FLEET_BIND_IP=10.87.0.11 ;;
      marshall-b) export MARSHALL_FLEET_BIND_IP=10.87.0.12 ;;
    esac
    export PHX_HOST="$MARSHALL_INSTANCE_ID"
    export MARSHALL_FLEET_LOOPBACK=false MARSHALL_FLEET_TLS_PORT=5443
    export MARSHALL_TLS_CERTFILE="$secrets/$MARSHALL_INSTANCE_ID.crt"
    export MARSHALL_TLS_KEYFILE="$secrets/$MARSHALL_INSTANCE_ID.key"
    [[ -s "$MARSHALL_TLS_CERTFILE" && -s "$MARSHALL_TLS_KEYFILE" ]] || { echo 'Marshall TLS unavailable' >&2; exit 1; }
    exec "$release" start
    ;;
  enroll)
    export MARSHALL_INSTANCE_ID=enrollment-operator PHX_SERVER=false
    unset PORT MARSHALL_TLS_CERTFILE MARSHALL_TLS_KEYFILE
    rm -f /tmp/enrollment-ready
    # Lilly publishes only public enrollment identity, then waits for the
    # operator-issued private envelope. A bound prevents a hanging setup.
    for ((attempt=0; attempt<180; attempt++)); do
      [[ -s "$secrets/lilly-a-enrollment.json" ]] && break
      sleep 1
    done
    [[ -s "$secrets/lilly-a-enrollment.json" ]] || { echo 'Lilly enrollment request unavailable' >&2; exit 1; }
    if [[ -s "$secrets/lilly-a-credential.json" ]]; then
      "$release" eval 'Marshall.Operations.CLI.main()' verify "$secrets/lilly-a-credential.json" >/dev/null
    else
      "$release" eval 'Marshall.Operations.CLI.main()' enroll "$secrets/lilly-a-enrollment.json" "$secrets/lilly-a-credential.json" >/dev/null
    fi
    "$release" eval 'Application.put_env(:marshall, :operator_mode, true); {:ok, _} = Application.ensure_all_started(:marshall); {:ok, public} = Marshall.Compute.Enrollment.describe("lilly-a"); File.write!("/run/overalls-secrets/.lilly-a-public.json", JSON.encode!(public))' >/dev/null
    pool_id=$(jq -er '.pools | select(type == "array" and length == 1) | .[0].id | select(type == "string" and test("^[0-9a-f-]{36}$"))' "$secrets/.lilly-a-public.json")
    printf '%s\n' "$pool_id" > "$secrets/.lilly-a-pool-id.new"
    chmod 0600 "$secrets/.lilly-a-pool-id.new"
    mv -f "$secrets/.lilly-a-pool-id.new" "$secrets/lilly-a-pool-id"
    rm -f "$secrets/.lilly-a-public.json"
    host_id=$(jq -er '.host_id | select(type == "string" and test("^[0-9a-f-]{36}$"))' "$secrets/lilly-a-credential.json")
    "$release" eval 'Application.put_env(:marshall, :operator_mode, true); {:ok, _} = Application.ensure_all_started(:marshall); [[version]] = Ecto.Adapters.SQL.query!(Marshall.Repo, "SELECT MAX(version) FROM schema_migrations", [], log: false).rows; File.write!("/tmp/migration-version", Integer.to_string(version))' >/dev/null
    migration_version=$(</tmp/migration-version)
    [[ "$migration_version" =~ ^[1-9][0-9]*$ ]] || { echo 'invalid migration version' >&2; exit 1; }
    oracle=/run/overalls-oracle
    [[ -s "$oracle/ca.crt" && -s "$oracle/oracle-password" ]] || { echo 'oracle credential volume unavailable' >&2; exit 1; }
    if [[ -s "$oracle/fixture.json" ]]; then
      fixture_id=$(jq -er --arg host "$host_id" --argjson migration "$migration_version" \
        'select(.schema_version == 1 and .migration_version == $migration and .host_ids == [$host]) | .fixture_id | select(type == "string" and test("^[0-9a-f]{32}$"))' "$oracle/fixture.json")
    else
      fixture_id=$(openssl rand -hex 16)
    fi
    jq -n --arg host "$host_id" --arg fixture "$fixture_id" --argjson migration "$migration_version" \
      '{schema_version:1, fixture_id:$fixture, migration_version:$migration, host_ids:[$host]}' > "$oracle/.fixture.json.new"
    chmod 0600 "$oracle/.fixture.json.new"
    mv -f "$oracle/.fixture.json.new" "$oracle/fixture.json"
    exec /opt/overalls/entrypoints/control-operator.sh
    ;;
esac
