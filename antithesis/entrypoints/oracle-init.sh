#!/usr/bin/env bash
set -euo pipefail
# The local PostgreSQL bootstrap runs this once, after creating the database.
# The password enters SQL over stdin and never a process argument.
password=$(<"${ANTITHESIS_PG_AUX:?}/oracle-password")
[[ "$password" =~ ^[0-9a-f]{64}$ ]] || { echo 'invalid oracle credential' >&2; exit 1; }
printf "CREATE ROLE overalls_oracle LOGIN PASSWORD '%s';\nGRANT CONNECT ON DATABASE overalls TO overalls_oracle;\n" "$password" |
  psql --no-psqlrc --set ON_ERROR_STOP=1 -U overalls -d overalls >/dev/null
unset password
