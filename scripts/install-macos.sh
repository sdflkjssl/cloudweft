#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export PATH="$HOME/.local/bin:$PATH"

fail() {
  printf '\nERROR: %s\n' "$*" >&2
  exit 1
}

[[ "$(uname -s)" == "Darwin" ]] || fail "This installer is for macOS only."

if ! xcrun --find swiftc >/dev/null 2>&1; then
  printf 'Apple Command Line Tools are required. macOS will open the installer now.\n'
  xcode-select --install 2>/dev/null || true
  printf 'Finish the Apple installation, then run this script again.\n'
  exit 2
fi

mkdir -p "$HOME/.local/bin"

if ! command -v node >/dev/null 2>&1; then
  case "$(uname -m)" in
    arm64) NODE_ARCH="arm64" ;;
    x86_64) NODE_ARCH="x64" ;;
    *) fail "Unsupported Mac architecture: $(uname -m)" ;;
  esac

  TMP_NODE="$(mktemp -d)"
  trap 'rm -rf "$TMP_NODE"' EXIT
  printf '[1/5] Installing a private Node.js runtime…\n'
  SHASUMS="$(curl -fsSL https://nodejs.org/dist/latest-v22.x/SHASUMS256.txt)"
  NODE_ASSET="$(printf '%s\n' "$SHASUMS" | awk -v arch="$NODE_ARCH" '$2 ~ ("node-v.*-darwin-" arch "\\.tar\\.gz$") {print $2; exit}')"
  [[ -n "$NODE_ASSET" ]] || fail "Could not determine the current Node.js macOS package."
  curl -fL "https://nodejs.org/dist/latest-v22.x/$NODE_ASSET" -o "$TMP_NODE/node.tar.gz"
  tar -xzf "$TMP_NODE/node.tar.gz" -C "$TMP_NODE"
  NODE_DIR="$TMP_NODE/${NODE_ASSET%.tar.gz}"
  cp "$NODE_DIR/bin/node" "$HOME/.local/bin/node"
  chmod 755 "$HOME/.local/bin/node"
else
  printf '[1/5] Node.js already available: %s\n' "$(command -v node)"
fi

printf '[2/5] Installing AList and CloudWeft background services…\n'
bash "$ROOT/scripts/install-services.sh"

printf '[3/5] Building CloudWeft and its File Provider extension…\n'
case "$(uname -m)" in
  arm64) SWIFT_ARCH="arm64" ;;
  x86_64) SWIFT_ARCH="x86_64" ;;
  *) fail "Unsupported Mac architecture: $(uname -m)" ;;
esac
TARGET="$SWIFT_ARCH-apple-macos13.0"
SDK="$(xcrun --show-sdk-path)"
BUILD="$(mktemp -d)"
APP="$BUILD/Plinth.app"
EXT="$APP/Contents/PlugIns/PlinthFileProvider.appex"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$EXT/Contents/MacOS" "$EXT/Contents/Resources"

xcrun swiftc -O -parse-as-library -module-name Plinth -target "$TARGET" -sdk "$SDK" \
  "$ROOT"/macos/App/*.swift "$ROOT"/macos/Shared/*.swift "$ROOT"/macos/Extension/Credentials.swift \
  -framework AppKit -framework FileProvider \
  -o "$APP/Contents/MacOS/Plinth"

xcrun swiftc -O -parse-as-library -module-name PlinthFileProvider -target "$TARGET" -sdk "$SDK" \
  "$ROOT"/macos/Extension/*.swift "$ROOT"/macos/Shared/*.swift \
  -framework Foundation -framework FileProvider -framework CryptoKit \
  -Xlinker -e -Xlinker _NSExtensionMain \
  -o "$EXT/Contents/MacOS/PlinthFileProvider"

cp "$ROOT/macos/Shared/providers.json" "$APP/Contents/Resources/providers.json"
cp "$ROOT/macos/Shared/providers.json" "$EXT/Contents/Resources/providers.json"

cp "$ROOT/macos/Info.plist" "$APP/Contents/Info.plist"
sed -i '' \
  -e 's/$(DEVELOPMENT_LANGUAGE)/en/g' \
  -e 's/$(EXECUTABLE_NAME)/Plinth/g' \
  -e 's/$(PRODUCT_BUNDLE_IDENTIFIER)/com.quarkpan.plinth/g' \
  -e 's/$(PRODUCT_NAME)/Plinth/g' \
  "$APP/Contents/Info.plist"

cp "$ROOT/macos/Extension/Info.plist" "$EXT/Contents/Info.plist"
sed -i '' \
  -e 's/$(DEVELOPMENT_LANGUAGE)/en/g' \
  -e 's/$(EXECUTABLE_NAME)/PlinthFileProvider/g' \
  -e 's/$(PRODUCT_BUNDLE_IDENTIFIER)/com.quarkpan.plinth.FileProvider/g' \
  -e 's/$(PRODUCT_NAME)/PlinthFileProvider/g' \
  -e 's/$(PRODUCT_MODULE_NAME)/PlinthFileProvider/g' \
  "$EXT/Contents/Info.plist"

codesign --force --sign - --options runtime --entitlements "$ROOT/macos/Extension/PlinthFileProvider.entitlements" "$EXT" >/dev/null
codesign --force --sign - --options runtime --entitlements "$ROOT/macos/App/Plinth.entitlements" "$APP" >/dev/null
codesign --verify --deep --strict "$APP"

printf '[4/5] Installing and enabling CloudWeft…\n'
if [[ -w /Applications ]]; then
  INSTALL_DIR="/Applications"
else
  INSTALL_DIR="$HOME/Applications"
  mkdir -p "$INSTALL_DIR"
fi
DEST="$INSTALL_DIR/Plinth.app"
pkill -x Plinth 2>/dev/null || true
rm -rf "$DEST"
cp -R "$APP" "$DEST"
pluginkit -a "$DEST/Contents/PlugIns/PlinthFileProvider.appex" 2>/dev/null || true
pluginkit -e use -i com.quarkpan.plinth.FileProvider 2>/dev/null || true

printf '[5/5] Starting CloudWeft…\n'
open "$DEST"
sleep 3
bash "$ROOT/scripts/plinth-doctor.sh" || true

printf '\nCloudWeft is installed.\n'
printf 'CloudWeft app (legacy bundle path): %s\n' "$DEST"
printf 'Next, configure Baidu by double-clicking scripts/setup-baidu.command\n'
