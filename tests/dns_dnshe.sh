#!/usr/bin/env sh
set -e
test_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
test_hook="${1:-$test_root/dnsapi/dns_dnshe.sh}"
test_acme="${2:-$test_root/acme.sh}"

# Load the real helpers without entering the CLI.
set -- _exists sh
. "$test_acme"
. "$test_hook"
ACCOUNT_CONF_PATH="$test_dir/account.conf"
test_writes="$test_dir/writes"
DEBUG=3
LOG_LEVEL=3

assert_request() {
  [ "$DEBUG" = 0 ] && [ "$ACME_HTTP_NO_REDIRECTS" = 1 ] &&
    [ "$_H1" = 'X-API-Key: dnshe-fixture-key' ] &&
    [ "$_H2" = 'X-API-Secret: dnshe-fixture-secret' ] &&
    [ "$_H3" = 'Accept: application/json' ] || exit 2
  case "$1" in
  'https://api005.dnshe.com/index.php?m=domain_hub&endpoint='*) ;;
  *) exit 2 ;;
  esac
}

_get() {
  assert_request "$1"
  case "${test_case:-}" in
  auth)
    printf 'HTTP/2 401\r\n' >"$HTTP_HEADER"
    printf '%s\n' '{"success":false,"error_code":"auth_invalid_credentials","message":"dnshe-fixture-secret"}'
    return
    ;;
  broken)
    printf 'HTTP/2 200\r\n' >"$HTTP_HEADER"
    printf '%s\n' '{"success":true,"subdomains":[{}'
    return
    ;;
  empty-page)
    printf 'HTTP/2 200\r\n' >"$HTTP_HEADER"
    printf '%s\n' '{"success":true,"subdomains":[],"pagination":{"has_more":true}}'
    return
    ;;
  esac
  printf 'HTTP/1.1 200 Connection established\r\n\r\nHTTP/2 200\r\n' >"$HTTP_HEADER"
  case "$1" in
  *'endpoint=subdomains&action=list&page=1&'*)
    printf '%s\n' '{"success":true,"subdomains":[{"id":5,"full_domain":"example.net","status":"active"}],"pagination":{"has_more":true}}'
    ;;
  *'endpoint=subdomains&action=list&page=2&'*)
    printf '%s\n' '{"success":true,"subdomains":[{"status":"Registered","full_domain":"Nested.Example.Net.","id":"123456789012345"},{"id":3,"full_domain":"ested.example.net","status":"active"}]}'
    ;;
  *'endpoint=dns_records&action=list&subdomain_id=123456789012345')
    if [ "${test_case:-}" = no-matches ]; then
      printf '%s\n' '{"success":true,"records":[]}'
      return
    fi
    cat <<'JSON'
{
  "success": true,
  "records": [
    {"id": 234567890123456, "name":"_ACME-CHALLENGE", "type":"TXT", "content":"\"root-token\""},
    {"id": 4, "name":"_acme-challenge.nested.example.net.", "type":"TXT", "content":"extra-token"},
    {"id": 6, "name":"_acme-challenge", "type":"A", "content":"root-token"},
    {"id": 7, "name":"wrong", "type":"TXT", "content":"root-token"},
    {"id": 8, "name":"wrong", "type":"TXT", "content":"punctuation: \"}],{\", \\ and unicode \u1234"}
  ]
}
JSON
    ;;
  *) exit 2 ;;
  esac
}

_post() {
  assert_request "$2"
  [ "$4" = POST ] && [ "$5" = application/json ] || exit 2
  printf '%s\n' "$1" >>"$test_writes"
  case "$2" in
  *'endpoint=dns_records&action=create')
    printf 'HTTP/2 201\r\n' >"$HTTP_HEADER"
    printf '%s\n' '{"success":true,"id":345678901234567}'
    ;;
  *'endpoint=dns_records&action=delete')
    printf 'HTTP/2 404\r\n' >"$HTTP_HEADER"
    printf '%s\n' '{"success":false,"error_code":"dns_record_not_found"}'
    ;;
  *) exit 2 ;;
  esac
}

DNSHE_API_KEY=dnshe-fixture-key
DNSHE_API_SECRET=dnshe-fixture-secret
test_name=_acme-challenge.nested.example.net

run_hook() (
  # acme.sh runs without errexit, including its base64 helper.
  set +e
  "$@"
)

run_hook dns_dnshe_add "$test_name" root-token >"$test_dir/output" 2>&1
[ ! -s "$test_dir/output" ]
[ ! -e "$test_writes" ]
run_hook dns_dnshe_add "$test_name" wildcard-token
unset DNSHE_API_KEY DNSHE_API_SECRET
run_hook dns_dnshe_rm "$test_name" root-token
test_case=no-matches run_hook dns_dnshe_rm "$test_name" root-token
cat >"$test_dir/expected" <<'JSON'
{"subdomain_id":123456789012345,"type":"TXT","name":"_acme-challenge","content":"wildcard-token"}
{"id":234567890123456}
JSON
diff -u "$test_dir/expected" "$test_writes"

for test_case in auth broken empty-page; do
  if run_hook dns_dnshe_add "$test_name" root-token >"$test_dir/output" 2>&1; then
    exit 1
  fi
  if grep -q 'dnshe-fixture-' "$test_dir/output"; then
    exit 1
  fi
done
diff -u "$test_dir/expected" "$test_writes"
printf '%s\n' 'DNSHE hook tests passed'
