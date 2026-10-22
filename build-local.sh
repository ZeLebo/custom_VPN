#!/bin/sh
# Local arm64 build with ad-hoc signing (no Apple Developer ID, no DMG).
# Output: build/macos/Build/Products/Release/CustomVPN.app
set -eu
cd "$(dirname "$0")"

# Needs Flutter 3.41.7 and Go 1.26 on PATH, or SDK_DIR=<dir containing flutter/ and go/>
if [ -n "${SDK_DIR:-}" ]; then
    export PATH="$SDK_DIR/go/bin:$SDK_DIR/flutter/bin:$PATH"
fi
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
# proxy.golang.org is unreliable from RU; go.sum pins the hashes anyway
export GOPROXY="${GOPROXY:-https://goproxy.io,direct}"
# Optional: route downloads through a running VPN, e.g. PROXY=http://127.0.0.1:7890
if [ -n "${PROXY:-}" ]; then
    export http_proxy="$PROXY" https_proxy="$PROXY" HTTP_PROXY="$PROXY" HTTPS_PROXY="$PROXY"
fi

# OFFLINE=1: build from the local pub and Go module caches, no network
if [ -n "${OFFLINE:-}" ]; then
    export GOPROXY=off GOFLAGS=-mod=mod
fi

printf 'CODE_SIGN_IDENTITY = -\nDEVELOPMENT_TEAM =\nARCHS = arm64\n' > macos/Runner/Configs/Local.xcconfig
rm -rf build/macos

flutter pub get ${OFFLINE:+--offline}
dart setup.dart macos --arch arm64 --out core

CORE_VERSION=$(awk '/metacubex\/mihomo v/{print $2; exit}' core/go.mod)
APP_VERSION=$(awk '/^version:/{split($2, v, "+"); print v[1]}' pubspec.yaml)
flutter build macos --release \
    --dart-define=APP_ENV=stable \
    --dart-define=CORE_VERSION="$CORE_VERSION" \
    --dart-define=APP_VERSION="$APP_VERSION"

APP=build/macos/Build/Products/Release/CustomVPN.app

# Embed zapret (utunws + scripts) for the Zapret tab, then reseal the bundle.
make -C zapret/nfq clean mac CC="$(xcrun -f clang)" SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
ZAPRET_OUT="$APP/Contents/Resources/zapret/Payload"
rm -rf "$ZAPRET_OUT"
mkdir -p "$(dirname "$ZAPRET_OUT")"
ditto zapret/payload "$ZAPRET_OUT"
cp zapret/nfq/utunws "$ZAPRET_OUT/bin/utunws"
chmod 755 "$ZAPRET_OUT"/*.sh "$ZAPRET_OUT/bin/utunws"
codesign --force --sign - "$ZAPRET_OUT/bin/utunws"
codesign --force --deep --sign - "$APP"
codesign --force --sign - --entitlements macos/Runner/Release.entitlements "$APP"
codesign --verify --deep --strict "$APP"
echo "built: $(pwd)/$APP"
