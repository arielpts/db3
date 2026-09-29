#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
[[ -f Vendor/PostgreSQL/lib/libpq.5.dylib ]] || python3 Scripts/prepare-postgres.py
if [[ "${1:-}" != "--integration" ]]; then
  swift test --package-path Packages/DB3Kit
  swift test --package-path .
  exit
fi
pg_bin="$(pg_config --bindir)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/db3-postgres.XXXXXX")"
test_port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
tls_port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
cleanup() {
  "$pg_bin/pg_ctl" -D "$test_dir/data" -m immediate stop >/dev/null 2>&1 || true
  "$pg_bin/pg_ctl" -D "$test_dir/tls-data" -m immediate stop >/dev/null 2>&1 || true
  "$pg_bin/pg_ctl" -D "$test_dir/auth-data" -m immediate stop >/dev/null 2>&1 || true
  rm -rf "$test_dir"
}
trap cleanup EXIT INT TERM
"$pg_bin/initdb" -D "$test_dir/data" --auth=trust --no-locale --encoding=UTF8 > "$test_dir/init.log"
"$pg_bin/pg_ctl" -D "$test_dir/data" -l "$test_dir/server.log" -o "-h 127.0.0.1 -p $test_port -k $test_dir" start
cat > "$test_dir/openssl.cnf" <<'CERT'
[req]
distinguished_name=dn
x509_extensions=extensions
prompt=no
[dn]
CN=localhost
[extensions]
subjectAltName=DNS:localhost
basicConstraints=critical,CA:TRUE
CERT
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$test_dir/server.key" -out "$test_dir/server.crt" -days 1 -config "$test_dir/openssl.cnf" > "$test_dir/cert.log" 2>&1
chmod 600 "$test_dir/server.key"
"$pg_bin/initdb" -D "$test_dir/tls-data" --auth=trust --no-locale --encoding=UTF8 > "$test_dir/tls-init.log"
"$pg_bin/pg_ctl" -D "$test_dir/tls-data" -l "$test_dir/tls-server.log" -o "-h 127.0.0.1 -p $tls_port -k $test_dir -c ssl=on -c ssl_cert_file=$test_dir/server.crt -c ssl_key_file=$test_dir/server.key" start
auth_port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
# A synthetic password and isolated SCRAM server exercise credential challenges.
auth_password="db3-catalog-fixture-password"
print -r -- "$auth_password" > "$test_dir/auth-password"
chmod 600 "$test_dir/auth-password"
"$pg_bin/initdb" -D "$test_dir/auth-data" --auth-local=trust --auth-host=scram-sha-256 --pwfile="$test_dir/auth-password" --no-locale --encoding=UTF8 > "$test_dir/auth-init.log"
"$pg_bin/pg_ctl" -D "$test_dir/auth-data" -l "$test_dir/auth-server.log" -o "-h 127.0.0.1 -p $auth_port -k $test_dir" start
DB3_TEST_PORT="$test_port" DB3_TEST_USER="$(id -un)" DB3_TEST_DATABASE=postgres DB3_TEST_EXPECT_TLS_FAILURE=1 DB3_TEST_TLS_PORT="$tls_port" DB3_TEST_TLS_CA="$test_dir/server.crt" DB3_TEST_AUTH_PORT="$auth_port" DB3_TEST_AUTH_USER="$(id -un)" DB3_TEST_AUTH_PASSWORD="$auth_password" swift test --package-path Packages/DB3Kit
swift test --package-path .
