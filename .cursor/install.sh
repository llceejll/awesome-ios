#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

AWESOME_BOT_VERSION=1.20.0
DANGER_VERSION=9.6.1
MARKDOWN_TO_HTML_CLI_VERSION=5.0.4
SWIFT_VERSION=6.4.0
# Pinned after verifying swift.org's detached GPG signature (key 52BB7E3DE28A71BE22EC05FFEF80A866B47A981F).
# That key expired on 2026-09-16, so gpg now reports it as good-but-expired; a checksum stays verifiable.
SWIFT_SHA256=69f7b2b4dbce6090b6c92194b71149a057e16269093b5a9dded38afc4a05094e

SUDO=""
[ "$(id -u)" -eq 0 ] || SUDO="sudo"

# Ruby 3.2 from apt rather than the 2.4.1 pinned in .travis.yml: danger 9.x requires Ruby >= 2.7.
# The rest are the Swift toolchain's runtime and link dependencies on Ubuntu 24.04.
APT_PACKAGES=(
  ruby ruby-dev build-essential ca-certificates curl git
  binutils unzip gnupg2 libc6-dev libcurl4-openssl-dev libedit2 libgcc-13-dev libpython3-dev
  libsqlite3-0 libstdc++-13-dev libxml2-dev libncurses-dev libz3-dev pkg-config tzdata zlib1g-dev
)
missing=()
for pkg in "${APT_PACKAGES[@]}"; do
  dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q '^install ok installed$' || missing+=("$pkg")
done
if [ "${#missing[@]}" -gt 0 ]; then
  $SUDO apt-get update -qq
  $SUDO apt-get install -y --no-install-recommends "${missing[@]}"
fi

ensure_gem() {
  gem list --installed "$1" --version "$2" >/dev/null 2>&1 \
    || $SUDO gem install --no-document "$1" --version "$2" </dev/null
}
ensure_gem awesome_bot "$AWESOME_BOT_VERSION"
ensure_gem danger "$DANGER_VERSION"

# `node` on PATH is Cursor's daemon binary, so npm derives "/" as its default global prefix; pin it.
md2html_pkg=/usr/local/lib/node_modules/markdown-to-html-cli/package.json
if [ "$(node -p "require('$md2html_pkg').version" 2>/dev/null || true)" != "$MARKDOWN_TO_HTML_CLI_VERSION" ]; then
  $SUDO env "PATH=$PATH" npm install --global --prefix /usr/local --ignore-scripts \
    "markdown-to-html-cli@$MARKDOWN_TO_HTML_CLI_VERSION"
fi

# Installed under /opt rather than extracted over /usr: the system already has its own clang there.
SWIFT_RELEASE="swift-${SWIFT_VERSION}-RELEASE"
SWIFT_ROOT="/opt/swift/${SWIFT_RELEASE}-ubuntu24.04"
if [ ! -x "$SWIFT_ROOT/usr/bin/swift" ]; then
  [ "$(uname -m)" = "x86_64" ] || { echo "The pinned Swift toolchain is x86_64 only" >&2; exit 1; }
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' EXIT
  curl -fsSL --retry 4 --retry-delay 5 -o "$workdir/swift.tar.gz" \
    "https://download.swift.org/swift-${SWIFT_VERSION}-release/ubuntu2404/${SWIFT_RELEASE}/${SWIFT_RELEASE}-ubuntu24.04.tar.gz"
  echo "${SWIFT_SHA256}  $workdir/swift.tar.gz" | sha256sum --check --status
  # Extract to a staging directory so an interrupted run never leaves a half-populated toolchain behind.
  $SUDO rm -rf /opt/swift/.staging
  $SUDO mkdir -p /opt/swift/.staging
  $SUDO tar -xzf "$workdir/swift.tar.gz" -C /opt/swift/.staging --no-same-owner
  $SUDO chmod -R o+rX "/opt/swift/.staging/${SWIFT_RELEASE}-ubuntu24.04"
  $SUDO mv "/opt/swift/.staging/${SWIFT_RELEASE}-ubuntu24.04" "$SWIFT_ROOT"
  $SUDO rmdir /opt/swift/.staging
fi
for tool in "$SWIFT_ROOT"/usr/bin/swift* "$SWIFT_ROOT"/usr/bin/sourcekit-lsp "$SWIFT_ROOT"/usr/bin/docc \
            "$SWIFT_ROOT"/usr/bin/lldb "$SWIFT_ROOT"/usr/bin/lldb-dap; do
  link="/usr/local/bin/$(basename "$tool")"
  if [ ! -e "$link" ] || [ -L "$link" ]; then
    $SUDO ln -sfn "$tool" "$link"
  fi
done

echo "ruby $(ruby -e 'print RUBY_VERSION') | awesome_bot $AWESOME_BOT_VERSION | danger $(danger --version) | markdown-to-html-cli $MARKDOWN_TO_HTML_CLI_VERSION | $(swift --version 2>&1 | head -1)"
