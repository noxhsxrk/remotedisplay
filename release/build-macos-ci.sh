#!/usr/bin/env bash
# Apple-silicon release packaging without developer certificates or test runs.
# Toolchains are provisioned by .github/workflows/macos-release.yml.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE="$ROOT/engine/rustdesk"
OUT="$ROOT/release/out"
VER="$(sed -n 's/^version: *\([^+]*\).*/\1/p' "$ROOT/client/pubspec.yaml")"
if [ "${RELEASE_TAG:-v$VER}" != "v$VER" ]; then
  echo "Release tag does not match client/pubspec.yaml" >&2
  exit 1
fi
if [ "$(uname -m)" != arm64 ]; then
  echo "This build requires an Apple-silicon runner" >&2
  exit 1
fi
: "${VCPKG_ROOT:?Set VCPKG_ROOT}"
: "${LIBCLANG_PATH:?Set LIBCLANG_PATH}"
mkdir -p "$OUT"
CLIENT_APP="$ROOT/client/build/macos/Build/Products/Release/RemoteDisplay.app"
SERVER_APP="$ROOT/server-mac/.build/Remote Display Server.app"

build_deps() {
echo "::group::Native codec dependencies"
git init "$VCPKG_ROOT"
git -C "$VCPKG_ROOT" remote add origin https://github.com/microsoft/vcpkg.git
git -C "$VCPKG_ROOT" fetch --depth 1 origin 120deac3062162151622ca4860575a33844ba10b
git -C "$VCPKG_ROOT" checkout --detach FETCH_HEAD
bash "$VCPKG_ROOT/bootstrap-vcpkg.sh" -disableMetrics
# Classic mode avoids building unused platform/FFmpeg dependencies. hwcodec
# obtains its FFmpeg build through the engine's pinned hwcodec dependency.
(
  cd "$VCPKG_ROOT"
  ./vcpkg install aom:arm64-osx opus:arm64-osx libvpx:arm64-osx \
    libyuv:arm64-osx libjpeg-turbo:arm64-osx \
    --overlay-ports="$ENGINE/res/vcpkg"
)
echo "::endgroup::"
}

build_bridge() {
echo "::group::Generate Flutter Rust bridge"
cargo install cargo-expand --version 1.0.95 --locked
cargo install flutter_rust_bridge_codegen --version 1.80.1 --features uuid --locked
(
  cd "$ENGINE/flutter"
  flutter pub get
)
(
  cd "$ENGINE"
  flutter_rust_bridge_codegen --rust-input src/flutter_ffi.rs \
    --dart-output flutter/lib/generated_bridge.dart \
    --c-output flutter/macos/Runner/bridge_generated.h \
    --llvm-path "$LIBCLANG_PATH"
)
cp "$ENGINE/flutter/macos/Runner/bridge_generated.h" "$ROOT/client/macos/Runner/bridge_generated.h"
echo "::endgroup::"
}

build_engine() {
echo "::group::Build both Rust engines"
(
  cd "$ENGINE"
  CARGO_PROFILE_RELEASE_STRIP=false cargo build --locked --release --features flutter,hwcodec --lib
  xcrun strip -x target/release/liblibrustdesk.dylib
  cargo build --locked --release --features hwcodec --bin rustdesk
)
echo "::endgroup::"
}

build_client() {
echo "::group::Build and ad-hoc sign client"
(
  cd "$ROOT/client"
  flutter pub get
  SIGN_ID=- bash build-sign.sh
)
echo "::endgroup::"
}

build_server() {
echo "::group::Build and ad-hoc sign server"
(
  cd "$ROOT/server-mac"
  make bundle ENGINE_BIN="$ENGINE/target/release/rustdesk"
)
codesign --force --sign - --options runtime --entitlements "$ROOT/server-mac/Entitlements.plist" \
  "$SERVER_APP/Contents/MacOS/remotedisplayd"
codesign --force --sign - --options runtime --entitlements "$ROOT/server-mac/Entitlements.plist" \
  "$SERVER_APP/Contents/MacOS/RemoteDisplayServer"
codesign --force --sign - --options runtime --entitlements "$ROOT/server-mac/Entitlements.plist" "$SERVER_APP"
echo "::endgroup::"
}

make_dmg() {
  local app="$1" bundle_name="$2" output="$3" stage
  stage="$(mktemp -d)"
  ditto "$app" "$stage/$bundle_name.app"
  ln -s /Applications "$stage/Applications"
  cp "$ROOT/LICENSE" "$stage/LICENSE.txt"
  cp "$ROOT/NOTICE.md" "$stage/NOTICE.md"
  hdiutil create -volname "$bundle_name" -srcfolder "$stage" -ov -format UDZO "$output"
  # stage is a disposable directory created by mktemp in this build job.
  rm -rf "$stage"
}

build_package() {
echo "::group::Package DMGs"
make_dmg "$CLIENT_APP" "Remote Display" "$OUT/RemoteDisplay-$VER-macos-client.dmg"
make_dmg "$SERVER_APP" "Remote Display Server" "$OUT/RemoteDisplay-Server-$VER-macos.dmg"
{
  echo "version=$VER"
  echo "source_commit=$(git -C "$ROOT" rev-parse HEAD)"
  echo "architecture=arm64"
  echo "signing=ad-hoc"
  echo "notarized=false"
  echo "tests=skipped at user request"
  echo "build_url=https://github.com/${GITHUB_REPOSITORY:-noxhsxrk/remotedisplay}/actions/runs/${GITHUB_RUN_ID:-local}"
} > "$OUT/RemoteDisplay-$VER-build-info.txt"
(
  cd "$OUT"
  shasum -a 256 ./*.dmg > SHA256SUMS.txt
)
echo "::endgroup::"
}

case "${1:-all}" in
  deps) build_deps ;;
  bridge) build_bridge ;;
  engine) build_engine ;;
  client) build_client ;;
  server) build_server ;;
  package) build_package ;;
  all) build_deps; build_bridge; build_engine; build_client; build_server; build_package ;;
  *) echo "Unknown build phase: $1" >&2; exit 2 ;;
esac
