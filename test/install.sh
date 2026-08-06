#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT_DIR
readonly INSTALLER="$ROOT_DIR/scripts/install.sh"

pass_count=0
fail_count=0

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  return 1
}

assert_file_exists() {
  [[ -f "$1" ]] || fail "Expected file to exist: $1"
}

assert_contains() {
  local needle="$1" file="$2"
  grep -F -- "$needle" "$file" >/dev/null || fail "Expected $file to contain: $needle"
}

assert_not_exists() {
  [[ ! -e "$1" ]] || fail "Expected path not to exist: $1"
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

setup_case() {
  CASE_DIR="$(mktemp -d)"
  MOCK_BIN="$CASE_DIR/mock-bin"
  FIXTURE_DIR="$CASE_DIR/fixture"
  INSTALL_DIR="$CASE_DIR/install"
  mkdir -p "$MOCK_BIN" "$FIXTURE_DIR"

  cat > "$FIXTURE_DIR/tronador" <<'SCRIPT'
#!/usr/bin/env bash
printf 'tronador test binary\n'
SCRIPT
  chmod +x "$FIXTURE_DIR/tronador"
  (
    cd "$FIXTURE_DIR"
    zip -q "$CASE_DIR/tronador.zip" tronador
  )
  local checksum
  checksum="$(sha256_file "$CASE_DIR/tronador.zip")"
  cat > "$CASE_DIR/checksums.txt" <<CHECKSUMS
$checksum  tronador-cli_9.8.7_linux_amd64.zip
$checksum  tronador-cli_1.2.3_linux_amd64.zip
$checksum  tronador-cli_2.3.4_darwin_arm64.zip
CHECKSUMS

  cat > "$MOCK_BIN/uname" <<'SCRIPT'
#!/usr/bin/env bash
case "$1" in
  -s) printf '%s\n' "$TEST_OS" ;;
  -m) printf '%s\n' "$TEST_ARCH" ;;
  *) exit 2 ;;
esac
SCRIPT
  chmod +x "$MOCK_BIN/uname"

  cat > "$MOCK_BIN/curl" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
output=''
url=''
expect_output=false
for argument in "$@"; do
  if "$expect_output"; then
    output="$argument"
    expect_output=false
  elif [[ "$argument" == '-o' || "$argument" == '--output' ]]; then
    expect_output=true
  elif [[ "$argument" != -* ]]; then
    url="$argument"
  fi
done
printf '%s\n' "$url" >> "$MOCK_CURL_LOG"
case "$url" in
  */releases/latest)
    printf '{"tag_name":"v9.8.7"}\n'
    ;;
  *.zip)
    cp "$MOCK_ARCHIVE" "$output"
    ;;
  *_SHA256SUMS)
    cp "$MOCK_CHECKSUMS" "$output"
    ;;
  *)
    printf 'unexpected curl URL: %s\n' "$url" >&2
    exit 1
    ;;
esac
SCRIPT
  chmod +x "$MOCK_BIN/curl"

  export TEST_OS='Linux'
  export TEST_ARCH='x86_64'
  export MOCK_ARCHIVE="$CASE_DIR/tronador.zip"
  export MOCK_CHECKSUMS="$CASE_DIR/checksums.txt"
  export MOCK_CURL_LOG="$CASE_DIR/curl.log"
  export GITHUB_OUTPUT="$CASE_DIR/github-output"
  export GITHUB_PATH="$CASE_DIR/github-path"
}

run_installer() {
  PATH="$MOCK_BIN:$PATH" INPUT_INSTALL_DIR="$INSTALL_DIR" "$@" bash "$INSTALLER"
}

run_test() {
  local name="$1"
  if "$name"; then
    printf 'PASS: %s\n' "$name"
    pass_count=$((pass_count + 1))
  else
    printf 'FAIL: %s\n' "$name" >&2
    fail_count=$((fail_count + 1))
  fi
}

test_latest_version_installs_and_sets_outputs() {
  setup_case
  run_installer env INPUT_VERSION='latest'
  assert_file_exists "$INSTALL_DIR/tronador" || return 1
  assert_contains 'version=v9.8.7' "$GITHUB_OUTPUT" || return 1
  assert_contains "path=$INSTALL_DIR/tronador" "$GITHUB_OUTPUT" || return 1
  assert_contains "$INSTALL_DIR" "$GITHUB_PATH" || return 1
  assert_contains '/releases/latest' "$MOCK_CURL_LOG" || return 1
  assert_contains '/releases/download/v9.8.7/tronador-cli_9.8.7_linux_amd64.zip' "$MOCK_CURL_LOG" || return 1
}

test_specific_version_is_normalized() {
  setup_case
  run_installer env INPUT_VERSION='1.2.3'
  assert_contains 'version=v1.2.3' "$GITHUB_OUTPUT" || return 1
  assert_contains '/releases/download/v1.2.3/tronador-cli_1.2.3_linux_amd64.zip' "$MOCK_CURL_LOG" || return 1
}

test_darwin_arm64_asset_is_selected() {
  setup_case
  export TEST_OS='Darwin'
  export TEST_ARCH='arm64'
  run_installer env INPUT_VERSION='v2.3.4'
  assert_contains 'version=v2.3.4' "$GITHUB_OUTPUT" || return 1
  assert_contains '/releases/download/v2.3.4/tronador-cli_2.3.4_darwin_arm64.zip' "$MOCK_CURL_LOG" || return 1
}

test_invalid_version_is_rejected_before_download() {
  setup_case
  if run_installer env INPUT_VERSION='../malicious'; then
    fail 'Installer accepted an unsafe version'
    return 1
  fi
  assert_not_exists "$INSTALL_DIR/tronador" || return 1
  [[ ! -f "$MOCK_CURL_LOG" ]] || { fail 'Installer attempted a download for an unsafe version'; return 1; }
}

test_relative_install_dir_is_rejected() {
  setup_case
  if PATH="$MOCK_BIN:$PATH" INPUT_VERSION='latest' INPUT_INSTALL_DIR='relative/bin' bash "$INSTALLER"; then
    fail 'Installer accepted a relative install directory'
    return 1
  fi
  [[ ! -f "$MOCK_CURL_LOG" ]] || { fail 'Installer attempted a download for a relative install directory'; return 1; }
}

test_checksum_mismatch_is_rejected() {
  setup_case
  printf '%064d  tronador-cli_1.2.3_linux_amd64.zip\n' 0 > "$MOCK_CHECKSUMS"
  if run_installer env INPUT_VERSION='1.2.3'; then
    fail 'Installer accepted a mismatched checksum'
    return 1
  fi
  assert_not_exists "$INSTALL_DIR/tronador" || return 1
}

run_test test_latest_version_installs_and_sets_outputs
run_test test_specific_version_is_normalized
run_test test_darwin_arm64_asset_is_selected
run_test test_invalid_version_is_rejected_before_download
run_test test_relative_install_dir_is_rejected
run_test test_checksum_mismatch_is_rejected

printf '%s passed, %s failed\n' "$pass_count" "$fail_count"
[[ "$fail_count" -eq 0 ]]
