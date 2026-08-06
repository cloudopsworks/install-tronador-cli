#!/usr/bin/env bash
set -euo pipefail

readonly REPOSITORY='cloudopsworks/tronador-cli'
readonly PROJECT_NAME='tronador-cli'
readonly BINARY_NAME='tronador'
TEMP_DIR=''

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

resolve_tag() {
  local requested_version="$1"

  if [[ -z "$requested_version" || "$requested_version" == 'latest' ]]; then
    local latest
    latest="$(curl --fail --silent --show-error --location --retry 3 --retry-delay 2 \
      "https://api.github.com/repos/${REPOSITORY}/releases/latest" \
      | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
      | head -n 1)"
    [[ -n "$latest" ]] || fail "Unable to resolve the latest stable Tronador release"
    printf '%s\n' "$latest"
    return
  fi

  [[ "$requested_version" =~ ^[0-9A-Za-z._-]+$ ]] \
    || fail "Version must be 'latest' or a release tag containing only letters, numbers, dots, underscores, and hyphens"

  if [[ "$requested_version" == v* ]]; then
    printf '%s\n' "$requested_version"
  else
    printf 'v%s\n' "$requested_version"
  fi
}

resolve_platform() {
  local os machine
  os="$(uname -s)"
  machine="$(uname -m)"

  case "$os" in
    Linux) platform='linux' ;;
    Darwin) platform='darwin' ;;
    *) fail "Unsupported operating system: $os. This action supports Linux and macOS." ;;
  esac

  case "$machine" in
    x86_64|amd64) architecture='amd64' ;;
    arm64|aarch64) architecture='arm64' ;;
    *) fail "Unsupported architecture: $machine" ;;
  esac
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

write_github_output() {
  local key="$1" value="$2"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$key" "$value" >> "$GITHUB_OUTPUT"
  fi
}

add_to_github_path() {
  if [[ -n "${GITHUB_PATH:-}" ]]; then
    printf '%s\n' "$1" >> "$GITHUB_PATH"
  fi
}

validate_install_dir() {
  local install_dir="$1"

  [[ "$install_dir" != *$'\n'* && "$install_dir" != *$'\r'* ]] \
    || fail 'install-dir must not contain a newline'
  [[ "$install_dir" == /* ]] \
    || fail 'install-dir must be an absolute path'
}

cleanup() {
  if [[ -n "${TEMP_DIR:-}" ]]; then
    rm -rf "$TEMP_DIR"
  fi
}

main() {
  require_command curl
  require_command unzip
  require_command install

  local tag asset_version archive checksums base_url archive_path checksums_path expected actual extracted_binary install_dir
  resolve_platform
  install_dir="${INPUT_INSTALL_DIR:-}"
  if [[ -z "$install_dir" ]]; then
    install_dir="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/tronador-cli/bin"
  fi
  validate_install_dir "$install_dir"

  tag="$(resolve_tag "${INPUT_VERSION:-latest}")"
  asset_version="${tag#v}"
  archive="${PROJECT_NAME}_${asset_version}_${platform}_${architecture}.zip"
  checksums="${PROJECT_NAME}_${asset_version}_SHA256SUMS"
  base_url="https://github.com/${REPOSITORY}/releases/download/${tag}"

  TEMP_DIR="$(mktemp -d)"
  trap cleanup EXIT
  archive_path="$TEMP_DIR/$archive"
  checksums_path="$TEMP_DIR/$checksums"

  printf 'Downloading Tronador %s for %s/%s\n' "$tag" "$platform" "$architecture"
  curl --fail --silent --show-error --location --retry 3 --retry-delay 2 --output "$archive_path" "$base_url/$archive"
  curl --fail --silent --show-error --location --retry 3 --retry-delay 2 --output "$checksums_path" "$base_url/$checksums"

  expected="$(awk -v archive="$archive" '$2 == archive || $2 == "*" archive { print $1; exit }' "$checksums_path")"
  [[ -n "$expected" ]] || fail "Checksum for $archive was not found in $checksums"
  actual="$(sha256_file "$archive_path")"
  [[ "$expected" == "$actual" ]] || fail "Checksum verification failed for $archive"

  unzip -q "$archive_path" -d "$TEMP_DIR/extract"
  extracted_binary="$(find "$TEMP_DIR/extract" -type f -name "$BINARY_NAME" -print -quit)"
  [[ -n "$extracted_binary" ]] || fail "Unable to find $BINARY_NAME in $archive"

  mkdir -p "$install_dir"
  install -m 0755 "$extracted_binary" "$install_dir/$BINARY_NAME"

  add_to_github_path "$install_dir"
  write_github_output version "$tag"
  write_github_output path "$install_dir/$BINARY_NAME"
  printf 'Installed %s %s to %s\n' "$BINARY_NAME" "$tag" "$install_dir/$BINARY_NAME"
}

main "$@"
