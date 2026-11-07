#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

export APP_TMP_DIR="$WORK_DIR/tmp"
export APP_NAME="pg-node-unit-test"
export APP_DIR="$WORK_DIR/app"
export DATA_DIR="$WORK_DIR/data"
mkdir -p "$APP_TMP_DIR" "$APP_DIR" "$DATA_DIR"

# Suppress IP-detection curl calls at source time
curl() { echo ""; return 0; }
export -f curl

export PG_NODE_SOURCE_ONLY="true"
# shellcheck source=pg-node.sh
source "$ROOT_DIR/pg-node.sh"

PASS=0
FAIL=0

pass() { echo "✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "✗ $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
    local actual="$1" expected="$2" label="$3"
    if [ "$actual" = "$expected" ]; then pass "$label"; else fail "$label (expected='$expected' got='$actual')"; fi
}

assert_true() {
    local label="$1"; shift
    if "$@"; then pass "$label"; else fail "$label"; fi
}

assert_false() {
    local label="$1"; shift
    if ! "$@"; then pass "$label"; else fail "$label"; fi
}

echo "=== unit_pgnode.sh ==="

# -----------------------------------------------------------------------
# is_ip_address
# -----------------------------------------------------------------------
assert_true  "is_ip_address: IPv4 basic"       is_ip_address "192.168.1.1"
assert_true  "is_ip_address: IPv4 zeros"        is_ip_address "0.0.0.0"
assert_true  "is_ip_address: IPv4 max"          is_ip_address "255.255.255.255"
assert_true  "is_ip_address: IPv4 10.x"         is_ip_address "10.0.0.1"
assert_true  "is_ip_address: IPv6 full"         is_ip_address "2001:db8::1"
assert_true  "is_ip_address: IPv6 loopback"     is_ip_address "::1"
assert_true  "is_ip_address: IPv6 double colon" is_ip_address "::"
assert_false "is_ip_address: octet > 255"       is_ip_address "256.0.0.1"
assert_false "is_ip_address: 3 octets"          is_ip_address "192.168.1"
assert_false "is_ip_address: domain"            is_ip_address "example.com"
assert_false "is_ip_address: empty"             is_ip_address ""
assert_false "is_ip_address: letters"           is_ip_address "abc.def.ghi.jkl"

# -----------------------------------------------------------------------
# normalize_san_entry
# -----------------------------------------------------------------------
assert_eq "$(normalize_san_entry "192.168.1.1")"        "IP:192.168.1.1"     "normalize_san_entry: bare IPv4 -> IP:"
assert_eq "$(normalize_san_entry "10.0.0.5")"           "IP:10.0.0.5"        "normalize_san_entry: bare IPv4 -> IP:"
assert_eq "$(normalize_san_entry "example.com")"        "DNS:example.com"    "normalize_san_entry: domain -> DNS:"
assert_eq "$(normalize_san_entry "sub.example.com")"    "DNS:sub.example.com" "normalize_san_entry: subdomain -> DNS:"
assert_eq "$(normalize_san_entry "*.example.com")"      "DNS:*.example.com"  "normalize_san_entry: wildcard -> DNS:"
assert_eq "$(normalize_san_entry "IP:10.0.0.1")"        "IP:10.0.0.1"        "normalize_san_entry: already prefixed IP: passthrough"
assert_eq "$(normalize_san_entry "DNS:example.com")"    "DNS:example.com"    "normalize_san_entry: already prefixed DNS: passthrough"
# Whitespace trimming
assert_eq "$(normalize_san_entry "  example.com  ")"   "DNS:example.com"    "normalize_san_entry: trims whitespace"
assert_eq "$(normalize_san_entry "  192.168.1.1  ")"   "IP:192.168.1.1"     "normalize_san_entry: trims whitespace on IP"

# -----------------------------------------------------------------------
# validate_san_entry
# -----------------------------------------------------------------------
assert_true  "validate_san_entry: IPv4"             validate_san_entry "192.168.1.1"
assert_true  "validate_san_entry: domain"           validate_san_entry "example.com"
assert_true  "validate_san_entry: subdomain"        validate_san_entry "sub.example.com"
assert_true  "validate_san_entry: wildcard domain"  validate_san_entry "*.example.com"
assert_true  "validate_san_entry: already IP:"      validate_san_entry "IP:10.0.0.1"
assert_true  "validate_san_entry: already DNS:"     validate_san_entry "DNS:example.com"
assert_true  "validate_san_entry: IPv6"             validate_san_entry "2001:db8::1"
assert_false "validate_san_entry: empty"            validate_san_entry ""
assert_false "validate_san_entry: whitespace only"  validate_san_entry "   "

# -----------------------------------------------------------------------
# validate_app_name  (guards --name against path/systemd/sed/yq injection)
# -----------------------------------------------------------------------
assert_true  "validate_app_name: simple"            validate_app_name "pg-node"
assert_true  "validate_app_name: with digit"        validate_app_name "node2"
# Docker Compose rejects uppercase project names (-p), so --name must be lowercase
assert_false "validate_app_name: uppercase"         validate_app_name "Node2"
assert_false "validate_app_name: non-ASCII letter"  validate_app_name "nodé"
assert_true  "validate_app_name: underscore"        validate_app_name "my_node"
assert_true  "validate_app_name: single char"       validate_app_name "a"
assert_true  "validate_app_name: digit start"       validate_app_name "2node"
assert_false "validate_app_name: empty"             validate_app_name ""
assert_false "validate_app_name: slash traversal"   validate_app_name "../etc/cron.d/x"
assert_false "validate_app_name: embedded slash"    validate_app_name "a/b"
assert_false "validate_app_name: space"             validate_app_name "a b"
assert_false "validate_app_name: newline"           validate_app_name $'a\nb'
assert_false "validate_app_name: pipe"              validate_app_name "a|b"
assert_false "validate_app_name: ampersand"         validate_app_name "a&b"
assert_false "validate_app_name: semicolon"         validate_app_name "a;b"
assert_false "validate_app_name: command sub"       validate_app_name 'a$(id)'
assert_false "validate_app_name: leading dash"      validate_app_name "-node"
assert_false "validate_app_name: dot"               validate_app_name "a.b"
assert_false "validate_app_name: too long"          validate_app_name "$(printf 'a%.0s' {1..64})"

# -----------------------------------------------------------------------
# resolve_node_image_tag  (--pre-release must install the dev image)
# -----------------------------------------------------------------------
assert_eq "$(resolve_node_image_tag "pre-release")" "dev"         "resolve_node_image_tag: pre-release -> dev"
assert_eq "$(resolve_node_image_tag "dev")"         "dev"         "resolve_node_image_tag: dev -> dev"
assert_eq "$(resolve_node_image_tag "latest")"      "latest"      "resolve_node_image_tag: latest -> latest"
assert_eq "$(resolve_node_image_tag "v0.5.7")"      "v0.5.7"      "resolve_node_image_tag: release tag kept"
assert_eq "$(resolve_node_image_tag "v1.0.0-rc.1")" "v1.0.0-rc.1" "resolve_node_image_tag: suffixed tag kept"
assert_false "resolve_node_image_tag: missing v"    resolve_node_image_tag "0.5.7"
assert_false "resolve_node_image_tag: two parts"    resolve_node_image_tag "v0.5"
assert_false "resolve_node_image_tag: empty"        resolve_node_image_tag ""
assert_false "resolve_node_image_tag: injection"    resolve_node_image_tag 'v0.5.7;id'

# -----------------------------------------------------------------------
# check_node_version_exists  (latest/dev never depend on the GitHub API)
# -----------------------------------------------------------------------
curl() { echo "unexpected curl call" >&2; return 1; }
assert_true  "check_node_version_exists: dev needs no API call"    check_node_version_exists "dev"
assert_true  "check_node_version_exists: latest needs no API call" check_node_version_exists "latest"
curl() { printf '200'; }
assert_true  "check_node_version_exists: release found (200)"      check_node_version_exists "v0.5.7"
curl() { printf '404'; }
assert_false "check_node_version_exists: missing release (404)"    check_node_version_exists "v9.9.9"
curl() { printf '403'; }
assert_true  "check_node_version_exists: rate limited -> proceed"  check_node_version_exists "v0.5.7"
curl() { printf '000'; return 7; }
assert_true  "check_node_version_exists: offline -> proceed"       check_node_version_exists "v0.5.7"
curl() { echo ""; return 0; }

# -----------------------------------------------------------------------
# set_node_image_tag  (needs mikefarah yq; CI runners ship it)
# -----------------------------------------------------------------------
if command -v yq >/dev/null 2>&1 && is_mikefarah_yq; then
    compose_test="$WORK_DIR/compose-test.yml"
    cp "$ROOT_DIR/docker-compose/node.yml" "$compose_test"
    assert_true "set_node_image_tag: latest -> dev" set_node_image_tag "dev" "$compose_test"
    assert_eq "$(yq eval -r '.services.node.image' "$compose_test")" "pasarguard/node:dev" "set_node_image_tag: image is :dev"
    assert_eq "$(yq eval -r '.services.node.container_name' "$compose_test")" "node" "set_node_image_tag: other keys untouched"
    printf 'services:\n  node:\n    image: pasarguard/node\n' >"$compose_test"
    set_node_image_tag "v0.5.7" "$compose_test"
    assert_eq "$(yq eval -r '.services.node.image' "$compose_test")" "pasarguard/node:v0.5.7" "set_node_image_tag: untagged image gets a tag"
    printf 'services:\n  node:\n    image: registry.local:5000/pasarguard/node:latest\n' >"$compose_test"
    set_node_image_tag "dev" "$compose_test"
    assert_eq "$(yq eval -r '.services.node.image' "$compose_test")" "registry.local:5000/pasarguard/node:dev" "set_node_image_tag: registry port kept"
else
    echo "(skipped set_node_image_tag: mikefarah yq not available)"
fi
# The post-write check must reject a rewrite that did not land as exactly one
# tag, whatever yq did, so the install stops instead of running :latest.
yq() { if [ "${1:-}" = "eval" ] && [ "${2:-}" = "-r" ]; then printf '%s\n' "$yq_result"; fi; return 0; }
for image_case in "pasarguard/node:dev|ok" "registry.local:5000/pasarguard/node:dev|ok" \
    "pasarguard/node:latest|fail" "pasarguard/node|fail" "pasarguard/node:dev:dev|fail"; do
    yq_result="${image_case%%|*}"
    if set_node_image_tag "dev" "/dev/null"; then got="ok"; else got="fail"; fi
    assert_eq "$got" "${image_case#*|}" "set_node_image_tag: verify '$yq_result' -> ${image_case#*|}"
done
unset -f yq

# -----------------------------------------------------------------------
# install_command: the version the options select must reach install_node
# (--pre-release used to resolve to the latest stable release instead of dev).
# Everything that touches the system is mocked; runs in a subshell.
# -----------------------------------------------------------------------
run_install_version() {
    (
        check_running_as_root() { :; }
        print_script_execution_header() { :; }
        detect_os() { :; }
        install_package() { :; }
        install_docker() { :; }
        ensure_docker_compose() { :; }
        install_yq() { :; }
        is_mikefarah_yq() { return 0; }
        detect_compose() { :; }
        is_node_installed() { return 1; }
        install_node() { echo "INSTALL_NODE_VERSION=$1"; SERVICE_PORT=62050; API_KEY="k"; }
        install_node_script() { :; }
        install_completion() { :; }
        up_node() { :; }
        show_node_logs() { :; }
        install_service_command() { :; }
        # latest/dev must not need the GitHub API; release tags get a 200
        curl() { printf '200'; }
        SSL_CERT_FILE=/dev/null
        install_command --no-install-service "$@"
    ) 2>&1 | grep -o 'INSTALL_NODE_VERSION=[^ ]*\|Cannot use[^.]*\|Invalid version format' | head -n 1
}
assert_eq "$(run_install_version --pre-release)"             "INSTALL_NODE_VERSION=dev"    "install: --pre-release installs dev"
assert_eq "$(run_install_version --dev)"                     "INSTALL_NODE_VERSION=dev"    "install: --dev installs dev"
assert_eq "$(run_install_version --version pre-release)"     "INSTALL_NODE_VERSION=dev"    "install: --version pre-release installs dev"
assert_eq "$(run_install_version)"                           "INSTALL_NODE_VERSION=latest" "install: default installs latest"
assert_eq "$(run_install_version --version v0.5.7)"          "INSTALL_NODE_VERSION=v0.5.7" "install: --version keeps the tag"
assert_eq "$(run_install_version --pre-release --version v0.5.7)" "Cannot use --pre-release, --dev and --version options simultaneously" "install: --pre-release with --version is rejected"
assert_eq "$(run_install_version --version 0.5.7)"           "Invalid version format"      "install: malformed --version is rejected"

# -----------------------------------------------------------------------
# is_valid_port
# -----------------------------------------------------------------------
assert_true  "is_valid_port: 1"           is_valid_port "1"
assert_true  "is_valid_port: 62050"       is_valid_port "62050"
assert_true  "is_valid_port: 65535"       is_valid_port "65535"
assert_false "is_valid_port: 0"           is_valid_port "0"
assert_false "is_valid_port: 65536"       is_valid_port "65536"
assert_false "is_valid_port: letters"     is_valid_port "abc"
assert_false "is_valid_port: mixed"       is_valid_port "1abc"
assert_false "is_valid_port: empty"       is_valid_port ""
assert_false "is_valid_port: arith expr"  is_valid_port 'a[$(id)]'

# -----------------------------------------------------------------------
# download_geofiles  (a failed download must not replace working files)
# -----------------------------------------------------------------------
geo_dir="$WORK_DIR/assets"
mkdir -p "$geo_dir"
printf 'old-geoip' >"$geo_dir/geoip.dat"
printf 'old-geosite' >"$geo_dir/geosite.dat"
# Mock: write the URL's file name into the -o target; fail for geosite.dat
curl() {
    local out="" url=""
    while [ $# -gt 0 ]; do
        case "$1" in
        -o) out="$2"; shift 2 ;;
        http*) url="$1"; shift ;;
        *) shift ;;
        esac
    done
    if [ "${GEO_FAIL:-}" = "${url##*/}" ]; then
        printf '<html>404</html>' >"$out"
        return 22
    fi
    printf 'new-%s' "${url##*/}" >"$out"
}
if (GEO_FAIL=geosite.dat download_geofiles "https://example.invalid/dl" "$geo_dir") >/dev/null 2>&1; then
    fail "download_geofiles: fails when a download fails"
else
    pass "download_geofiles: fails when a download fails"
fi
assert_eq "$(cat "$geo_dir/geoip.dat")"   "old-geoip"   "download_geofiles: geoip.dat kept on failure"
assert_eq "$(cat "$geo_dir/geosite.dat")" "old-geosite" "download_geofiles: geosite.dat kept on failure"
assert_eq "$(find "$geo_dir" -name '.*' -type f | wc -l | tr -d ' ')" "0" "download_geofiles: no temp files left on failure"
download_geofiles "https://example.invalid/dl" "$geo_dir" >/dev/null 2>&1
assert_eq "$(cat "$geo_dir/geoip.dat")"   "new-geoip.dat"   "download_geofiles: geoip.dat replaced on success"
assert_eq "$(cat "$geo_dir/geosite.dat")" "new-geosite.dat" "download_geofiles: geosite.dat replaced on success"
curl() { echo ""; return 0; }

# -----------------------------------------------------------------------
# generate_uuid_v4
# -----------------------------------------------------------------------
cat() { return 1; }
uuidgen() { return 1; }
python3() {
    if [ "${1:-}" = "-c" ]; then
        echo "11111111-2222-4333-8444-555555555555"
        return 0
    fi
    return 1
}
export -f cat uuidgen python3
assert_eq "$(generate_uuid_v4)" "11111111-2222-4333-8444-555555555555" \
    "generate_uuid_v4: falls back to python3"
unset -f cat uuidgen python3

# -----------------------------------------------------------------------
# openssl_supports_addext
# -----------------------------------------------------------------------
openssl() {
    if [ "${1:-}" = "req" ] && [ "${2:-}" = "-help" ]; then
        echo "Usage: openssl req [-addext ext]"
        return 0
    fi
    return 1
}
export -f openssl
assert_true "openssl_supports_addext: detects -addext support" openssl_supports_addext

openssl() {
    if [ "${1:-}" = "req" ] && [ "${2:-}" = "-help" ]; then
        echo "Usage: openssl req"
        return 0
    fi
    return 1
}
export -f openssl
assert_false "openssl_supports_addext: handles older OpenSSL help" openssl_supports_addext
unset -f openssl

# -----------------------------------------------------------------------
# gen_self_signed_cert  (must leave the private key owner-readable only)
# -----------------------------------------------------------------------
if command -v openssl >/dev/null 2>&1; then
    cert_test_dir="$WORK_DIR/certtest/certs"
    mkdir -p "$cert_test_dir"
    SSL_CERT_FILE="$cert_test_dir/ssl_cert.pem"
    SSL_KEY_FILE="$cert_test_dir/ssl_key.pem"
    AUTO_CONFIRM=true
    INSTALL_SAN_ENTRIES=""
    # Simulate a re-install/renew over a previously world-readable key:
    # openssl -keyout truncates in place and preserves the existing 0644 mode,
    # so the key would stay world-readable without explicit hardening.
    install -m 644 /dev/null "$SSL_KEY_FILE"
    gen_self_signed_cert >/dev/null 2>&1
    if [ -f "$SSL_KEY_FILE" ]; then
        pass "gen_self_signed_cert: key generated"
        assert_eq "$(stat -c '%a' "$SSL_KEY_FILE")" "600" "gen_self_signed_cert: private key is 0600"
    else
        fail "gen_self_signed_cert: key generated"
    fi
    AUTO_CONFIRM=false
    # Restore globals to source-time values for later tests
    SSL_CERT_FILE="$DATA_DIR/certs/ssl_cert.pem"
    SSL_KEY_FILE="$DATA_DIR/certs/ssl_key.pem"
else
    echo "(skipped gen_self_signed_cert: openssl not available)"
fi

# -----------------------------------------------------------------------
# detect_node_serviced_platform
# -----------------------------------------------------------------------
# Mock uname
uname() {
    case "${1:-}" in
        -s) echo "Linux" ;;
        -m) echo "x86_64" ;;
    esac
}
export -f uname
assert_eq "$(detect_node_serviced_platform)" "Linux_x86_64" \
    "detect_node_serviced_platform: identifies x86_64"

uname() {
    case "${1:-}" in
        -s) echo "Linux" ;;
        -m) echo "aarch64" ;;
    esac
}
export -f uname
assert_eq "$(detect_node_serviced_platform)" "Linux_arm64" \
    "detect_node_serviced_platform: identifies arm64"
unset -f uname

# -----------------------------------------------------------------------
# is_port_occupied
# -----------------------------------------------------------------------
OCCUPIED_PORTS=$(printf "80\n443\n62051\n")
assert_true  "is_port_occupied: 80 is busy"    is_port_occupied 80
assert_true  "is_port_occupied: 62051 is busy" is_port_occupied 62051
assert_false "is_port_occupied: 9000 is free"  is_port_occupied 9000

# -----------------------------------------------------------------------
# is_node_installed  (APP_DIR is a temp dir we created)
# -----------------------------------------------------------------------
assert_true  "is_node_installed: APP_DIR exists"   is_node_installed
rm -rf "$APP_DIR"
assert_false "is_node_installed: APP_DIR missing"  is_node_installed
mkdir -p "$APP_DIR"

# -----------------------------------------------------------------------
# sync_env_ssl_paths
# Skips when APP_NAME="pg-node"; updates old /var/lib/pg-node/ paths;
# appends if key is missing; is no-op when ENV_FILE doesn't exist.
# -----------------------------------------------------------------------

# Case 1: APP_NAME is the default "pg-node" — function exits immediately
APP_NAME="pg-node"
cat > "$ENV_FILE" <<'EOF'
SSL_CERT_FILE= /var/lib/pg-node/certs/ssl_cert.pem
SSL_KEY_FILE= /var/lib/pg-node/certs/ssl_key.pem
EOF
sync_env_ssl_paths
if grep -q "/var/lib/pg-node/" "$ENV_FILE"; then
    pass "sync_env_ssl_paths: no-op when APP_NAME=pg-node"
else
    fail "sync_env_ssl_paths: no-op when APP_NAME=pg-node"
fi

# Case 2: custom APP_NAME with old pg-node paths — should update them
APP_NAME="my-node"
DATA_DIR="$WORK_DIR/my-node-data"
APP_DIR="$WORK_DIR/my-node-app"
ENV_FILE="$APP_DIR/.env"
mkdir -p "$APP_DIR" "$DATA_DIR"
cat > "$ENV_FILE" <<'EOF'
SSL_CERT_FILE= /var/lib/pg-node/certs/ssl_cert.pem
SSL_KEY_FILE= /var/lib/pg-node/certs/ssl_key.pem
EOF
sync_env_ssl_paths
expected_cert="$DATA_DIR/certs/ssl_cert.pem"
expected_key="$DATA_DIR/certs/ssl_key.pem"
if grep -q "SSL_CERT_FILE= $expected_cert" "$ENV_FILE"; then
    pass "sync_env_ssl_paths: cert path updated for custom APP_NAME"
else
    fail "sync_env_ssl_paths: cert path updated for custom APP_NAME (got: $(grep SSL_CERT_FILE "$ENV_FILE"))"
fi
if grep -q "SSL_KEY_FILE= $expected_key" "$ENV_FILE"; then
    pass "sync_env_ssl_paths: key path updated for custom APP_NAME"
else
    fail "sync_env_ssl_paths: key path updated for custom APP_NAME (got: $(grep SSL_KEY_FILE "$ENV_FILE"))"
fi

# Case 3: custom APP_NAME with correct paths already — should NOT change them
cat > "$ENV_FILE" <<EOF
SSL_CERT_FILE= $expected_cert
SSL_KEY_FILE= $expected_key
EOF
sync_env_ssl_paths
if grep -q "SSL_CERT_FILE= $expected_cert" "$ENV_FILE"; then
    pass "sync_env_ssl_paths: already-correct paths left unchanged"
else
    fail "sync_env_ssl_paths: already-correct paths left unchanged"
fi

# Case 4: missing ENV_FILE — function must not crash
APP_NAME="my-node"
ENV_FILE="/nonexistent/dir/.env"
sync_env_ssl_paths
pass "sync_env_ssl_paths: no crash when ENV_FILE missing"

# Case 5: ENV_FILE not readable (a non-root user running e.g. status) — must
# return instead of failing on sed -i and aborting the command under set -e
ENV_FILE="$APP_DIR/.env"
printf 'SSL_CERT_FILE= /var/lib/pg-node/certs/ssl_cert.pem\n' >"$ENV_FILE"
chmod 000 "$ENV_FILE"
if [ -r "$ENV_FILE" ]; then
    echo "(skipped sync_env_ssl_paths unreadable case: file still readable, e.g. running as root)"
elif (set -e; sync_env_ssl_paths) >/dev/null 2>&1; then
    pass "sync_env_ssl_paths: returns quietly when ENV_FILE is unreadable"
else
    fail "sync_env_ssl_paths: returns quietly when ENV_FILE is unreadable"
fi
chmod 600 "$ENV_FILE"

# -----------------------------------------------------------------------
# version-script CLI command & completions
# -----------------------------------------------------------------------
ver_out=$(pg_node_main version-script)
if [[ "$ver_out" == *"# Executing pg-node script, commit:"* ]]; then
    pass "version-script: output contains '# Executing pg-node script, commit:'"
else
    fail "version-script: output contains '# Executing pg-node script, commit:'"
fi

bash_comp_out=$(generate_bash_completion)
if [[ "$bash_comp_out" == *"version-script"* && "$bash_comp_out" == *"script-version"* ]]; then
    pass "bash completion: contains version-script and script-version"
else
    fail "bash completion: contains version-script and script-version"
fi

zsh_comp_out=$(generate_zsh_completion)
if [[ "$zsh_comp_out" == *"version-script"* && "$zsh_comp_out" == *"script-version"* ]]; then
    pass "zsh completion: contains version-script and script-version"
else
    fail "zsh completion: contains version-script and script-version"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
