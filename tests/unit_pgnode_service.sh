#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# Source only the function definitions; skip the server/env-validation body.
export PG_NODE_SERVICE_SOURCE_ONLY="true"
# shellcheck source=pg-node-service.sh
source "$ROOT_DIR/pg-node-service.sh"

PASS=0
FAIL=0
pass() { echo "✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "✗ $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
    local actual="$1" expected="$2" label="$3"
    if [ "$actual" = "$expected" ]; then pass "$label"; else fail "$label (expected='$expected' got='$actual')"; fi
}
assert_contains() {
    local haystack="$1" needle="$2" label="$3"
    if [[ "$haystack" == *"$needle"* ]]; then pass "$label"; else fail "$label (missing '$needle' in: $haystack)"; fi
}

echo "=== unit_pgnode_service.sh ==="

# -----------------------------------------------------------------------
# check_certificate on real certificates: the self-signed install default
# must be detected (comparing openssl's raw "subject=" / "issuer=" lines
# never matched, so every certificate was reported as CA-signed).
# -----------------------------------------------------------------------
if command -v openssl >/dev/null 2>&1; then
    self_cert="$WORK_DIR/self.pem"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 \
        -keyout "$WORK_DIR/self.key" -out "$self_cert" -subj "/CN=203.0.113.10" >/dev/null 2>&1
    status=0
    check_certificate "$self_cert" >/dev/null 2>&1 || status=$?
    assert_eq "$status" "2" "check_certificate: self-signed cert -> 2"

    # A leaf signed by a separate CA has issuer != subject
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 \
        -keyout "$WORK_DIR/ca.key" -out "$WORK_DIR/ca.pem" -subj "/CN=Test CA" >/dev/null 2>&1
    openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
        -keyout "$WORK_DIR/leaf.key" -out "$WORK_DIR/leaf.csr" -subj "/CN=node.example.com" >/dev/null 2>&1
    openssl x509 -req -in "$WORK_DIR/leaf.csr" -CA "$WORK_DIR/ca.pem" -CAkey "$WORK_DIR/ca.key" \
        -CAcreateserial -days 1 -out "$WORK_DIR/leaf.pem" >/dev/null 2>&1
    status=0
    check_certificate "$WORK_DIR/leaf.pem" >/dev/null 2>&1 || status=$?
    assert_eq "$status" "0" "check_certificate: CA-signed cert -> 0"

    printf 'not a certificate\n' >"$WORK_DIR/bad.pem"
    status=0
    check_certificate "$WORK_DIR/bad.pem" >/dev/null 2>&1 || status=$?
    assert_eq "$status" "1" "check_certificate: invalid file -> 1"
else
    echo "(skipped check_certificate: openssl not available)"
fi

# -----------------------------------------------------------------------
# describe_certificate must map each check_certificate status to the right
# message. The original code read $? inside `if ...; then`, where it is always
# 0, so the self-signed (2) and invalid (1) branches were dead.
# -----------------------------------------------------------------------
check_certificate() { return 0; }   # CA-signed
out=$(describe_certificate "/tmp/cert.pem" 2>&1)
if echo "$out" | grep -q "CA-signed"; then pass "describe_certificate: status 0 -> CA-signed"; else fail "describe_certificate: status 0 -> CA-signed (got: $out)"; fi

check_certificate() { return 2; }   # self-signed
out=$(describe_certificate "/tmp/cert.pem" 2>&1)
if echo "$out" | grep -q "self-signed"; then pass "describe_certificate: status 2 -> self-signed"; else fail "describe_certificate: status 2 -> self-signed (got: $out)"; fi

check_certificate() { return 1; }   # invalid
out=$(describe_certificate "/tmp/cert.pem" 2>&1)
if echo "$out" | grep -q "validation failed"; then pass "describe_certificate: status 1 -> validation failed"; else fail "describe_certificate: status 1 -> validation failed (got: $out)"; fi

# describe_certificate must not abort the caller under set -e when the cert is
# self-signed/invalid (non-zero check_certificate).
check_certificate() { return 2; }
if ( set -e; describe_certificate "/tmp/cert.pem" >/dev/null 2>&1; echo ok ) | grep -q ok; then
    pass "describe_certificate: survives set -e on non-zero status"
else
    fail "describe_certificate: survives set -e on non-zero status"
fi

# byte_length must count bytes (for Content-Length), not characters: a
# multibyte UTF-8 body otherwise advertises a too-small length and truncates.
assert_eq "$(byte_length "hello")" "5" "byte_length: ASCII counts bytes"
assert_eq "$(byte_length "")" "0" "byte_length: empty is 0"
# 'é' is 2 bytes in UTF-8, so "café" is 5 bytes though ${#} reports 4 chars.
assert_eq "$(byte_length "café")" "5" "byte_length: multibyte UTF-8 counts bytes"
# A JSON body with an embedded multibyte error message.
multibyte_body='{"detail":"versión inválida"}'
assert_eq "$(byte_length "$multibyte_body")" "$(printf '%s' "$multibyte_body" | wc -c | tr -d '[:space:]')" "byte_length: matches wc -c"

# -----------------------------------------------------------------------
# Request handling. jq and the node CLI are mocked: jq prints the
# core_version the test sets, and the CLI records how it was called.
# -----------------------------------------------------------------------
API_KEY="secret-key"
APP_NAME="fake_node_cli"
CLI_LOG="$WORK_DIR/cli.log"
fake_node_cli() { printf '%s\n' "$*" >>"$CLI_LOG"; return "${FAKE_CLI_STATUS:-0}"; }
jq() { cat >/dev/null; printf '%s\n' "${MOCK_CORE_VERSION:-}"; }

core_update() {
    : >"$CLI_LOG"
    MOCK_CORE_VERSION="$1" handle_node_core_update '{"core_version":"x"}' 2>/dev/null
}

out=$(core_update "")
assert_contains "$out" "HTTP/1.1 400" "core_update: missing core_version -> 400"
assert_contains "$out" "core_version is required" "core_update: missing core_version message"
assert_eq "$(cat "$CLI_LOG")" "" "core_update: missing core_version runs nothing"

out=$(core_update "latest")
assert_contains "$out" "HTTP/1.1 200" "core_update: latest -> 200"
assert_eq "$(cat "$CLI_LOG")" "core-update --version latest" "core_update: latest passed through"

out=$(core_update "25.10.15")
assert_contains "$out" "HTTP/1.1 200" "core_update: bare X.Y.Z -> 200"
assert_eq "$(cat "$CLI_LOG")" "core-update --version v25.10.15" "core_update: bare X.Y.Z gets a v prefix"

out=$(core_update 'v1.0.0;reboot')
assert_contains "$out" "HTTP/1.1 400" "core_update: malformed version -> 400"
assert_eq "$(cat "$CLI_LOG")" "" "core_update: malformed version runs nothing"

out=$(FAKE_CLI_STATUS=1 core_update "v99.0.0")
assert_contains "$out" "HTTP/1.1 404" "core_update: CLI failure -> 404"

: >"$CLI_LOG"
out=$(FAKE_CLI_STATUS=3 handle_node_update 2>&1)
assert_contains "$out" "exit code: 3" "node_update: logs the real exit code"
assert_contains "$out" "HTTP/1.1 500" "node_update: failure -> 500"

# handle_connection: header names are case-insensitive and values may have
# optional whitespace (the old Content-Length regex needed exactly one space).
request() {
    printf '%b' "$1" | handle_connection 2>/dev/null || true
}

out=$(request 'GET / HTTP/1.1\r\nx-api-key:   secret-key  \r\n\r\n')
assert_contains "$out" "HTTP/1.1 200" "handle_connection: trims the x-api-key value"

out=$(request 'GET / HTTP/1.1\r\nX-Api-Key: wrong\r\n\r\n')
assert_contains "$out" "HTTP/1.1 401" "handle_connection: wrong api key -> 401"

body='{"core_version":"latest"}'
out=$(MOCK_CORE_VERSION=latest request "POST /node/core_update HTTP/1.1\r\nCONTENT-LENGTH:${#body}\r\nx-api-key: secret-key\r\n\r\n${body}")
assert_contains "$out" "HTTP/1.1 200" "handle_connection: reads a body sized by CONTENT-LENGTH:N (no space)"

out=$(request 'POST /node/core_update HTTP/1.1\r\nContent-Length: 12abc\r\nx-api-key: secret-key\r\n\r\n')
assert_contains "$out" "HTTP/1.1 400" "handle_connection: invalid Content-Length -> 400"

body='{}'
out=$(MOCK_CORE_VERSION="" request "POST /node/core_update HTTP/1.1\r\nContent-Length: ${#body}\r\nx-api-key: secret-key\r\n\r\n${body}")
assert_contains "$out" "HTTP/1.1 400" "handle_connection: core_update without core_version gets a reply"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
