#!/usr/bin/env bash
# One-line installer for kme.
#   curl -fsSL https://raw.githubusercontent.com/imapotatoes11/kme/main/install.sh | bash
#
# It downloads the prebuilt binary for your platform from the latest release
# (a signed, notarised universal binary on macOS; a static, dependency-free
# binary on Linux) and copies it onto your PATH. If no prebuilt matches, or you
# pass FROM_SOURCE=1, it builds from source instead (needs a Swift toolchain).
#
# Override the destination with PREFIX, e.g. PREFIX="$HOME/.local/bin" ... | bash
set -euo pipefail

PREFIX="${PREFIX:-/usr/local/bin}"
REPO="imapotatoes11/kme"
FROM_SOURCE="${FROM_SOURCE:-0}"

# Copy a file into PREFIX, escalating to sudo only if PREFIX isn't writable.
install_bin() {
    local src="$1"
    if mkdir -p "$PREFIX" 2>/dev/null && install -m 0755 "$src" "$PREFIX/kme" 2>/dev/null; then
        return
    fi
    echo "==> $PREFIX needs elevated permissions; using sudo for the copy"
    sudo mkdir -p "$PREFIX"
    sudo install -m 0755 "$src" "$PREFIX/kme"
}

# Build from source as a fallback (original behaviour).
build_from_source() {
    command -v swift >/dev/null 2>&1 || {
        echo "error: no prebuilt binary for this platform and 'swift' was not found." >&2
        echo "       Install a Swift 6+ toolchain (https://www.swift.org/install) and retry." >&2
        exit 1
    }
    local tmp; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
    echo "==> Cloning kme"
    git clone --depth 1 "https://github.com/$REPO.git" "$tmp"
    echo "==> Building (release)"
    ( cd "$tmp" && swift build -c release )
    install_bin "$tmp/.build/release/kme"
}

# Resolve the asset name for this OS/arch, or return non-zero if none exists.
asset_for_platform() {
    local os arch; os="$(uname -s)"; arch="$(uname -m)"
    case "$os" in
        Darwin) echo "kme-VERSION-macos-universal.zip" ;;  # universal: any Mac arch
        Linux)
            case "$arch" in
                x86_64|amd64)  echo "kme-VERSION-linux-x86_64.tar.gz" ;;
                aarch64|arm64) echo "kme-VERSION-linux-aarch64.tar.gz" ;;
                *) return 1 ;;
            esac ;;
        *) return 1 ;;
    esac
}

# Latest release tag from the GitHub API.
latest_version() {
    curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
        | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/'
}

install_prebuilt() {
    local version asset url tmp out
    version="$(latest_version)" || return 1
    [ -n "$version" ] || return 1
    asset="$(asset_for_platform)" || return 1
    asset="${asset/VERSION/$version}"
    url="https://github.com/$REPO/releases/download/$version/$asset"

    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
    echo "==> Downloading $asset ($version)"
    curl -fSL --proto '=https' -o "$tmp/$asset" "$url" || return 1

    case "$asset" in
        *.zip)    ( cd "$tmp" && unzip -q "$asset" ) ;;
        *.tar.gz) ( cd "$tmp" && tar -xzf "$asset" ) ;;
    esac
    out="$tmp/kme"
    [ -f "$out" ] || { echo "error: archive did not contain 'kme'." >&2; return 1; }
    chmod +x "$out"
    install_bin "$out"
}

if [ "$FROM_SOURCE" = "1" ]; then
    build_from_source
elif ! install_prebuilt; then
    echo "==> No prebuilt available (or download failed); building from source"
    build_from_source
fi

echo "==> Installed kme to $PREFIX/kme"
"$PREFIX/kme" --version
