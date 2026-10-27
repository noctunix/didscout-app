#!/usr/bin/env bash
# Build a signed arm64-v8a release APK and install it if exactly one compatible
# device is connected (or ANDROID_SERIAL selects one).
# Requires keystore.properties in the project directory; see keystore.properties.example.
#
# Android Studio: the "Release APK (arm64)" run configuration in .run/ starts
# this script. A Gradle run configuration would only build, not install.
#
#   scripts/build-release-arm64.sh               build and install
#   scripts/build-release-arm64.sh --no-install  build only
set -euo pipefail

cd "$(dirname "$0")/.."

install=true
case "${1:-}" in
    "") ;;
    --no-install) install=false ;;
    *) echo "Unknown option: $1 (allowed: --no-install)" >&2; exit 2 ;;
esac

if [[ ! -f keystore.properties ]]; then
    echo "keystore.properties is missing; see keystore.properties.example" >&2
    exit 1
fi

flutter build apk --release --target-platform android-arm64

apk=build/app/outputs/flutter-apk/app-release.apk
size_mb=$(awk -v b="$(wc -c < "$apk")" 'BEGIN { printf "%.1f", b / 1048576 }')
version=$(sed -n 's/^version: \([^+]*\).*$/\1/p' pubspec.yaml)
printf '\nRelease-APK %s (arm64-v8a): %s  %s MB\n' "$version" "$apk" "$size_mb"

# A version should identify one exact state: a tagged commit without local changes.
if ! git describe --exact-match --tags --match "v$version" HEAD > /dev/null 2>&1; then
    echo "Note: this commit is not tagged v$version; bump the version and tag the commit."
elif [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
    echo "Note: local changes mean this APK does not exactly match v$version."
fi

[[ "$install" == true ]] || exit 0

# Find adb on PATH or in the SDK (ANDROID_HOME or sdk.dir in android/local.properties).
adb=$(command -v adb || true)
if [[ -z "$adb" ]]; then
    sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}
    if [[ -z "$sdk" && -f android/local.properties ]]; then
        sdk=$(sed -n 's/^sdk\.dir=//p' android/local.properties | sed 's/\\:/:/g; s/\\\\/\\/g')
    fi
    [[ -n "$sdk" && -x "$sdk/platform-tools/adb" ]] && adb="$sdk/platform-tools/adb"
fi
if [[ -z "$adb" ]]; then
    echo "Note: adb not found; installation skipped."
    exit 0
fi

if [[ -n "${ANDROID_SERIAL:-}" ]]; then
    serial=$ANDROID_SERIAL
else
    # Treat a failed "adb devices" (e.g. server unavailable) as no connected devices.
    devices=$("$adb" devices 2>/dev/null | awk -F'\t' '$2 == "device" { print $1 }' || true)
    count=$(printf '%s' "$devices" | grep -c . || true)
    if [[ "$count" -eq 0 ]]; then
        echo "Note: no device connected; installation skipped."
        exit 0
    elif [[ "$count" -gt 1 ]]; then
        echo "Note: $count devices connected; installation skipped. Select one with:"
        echo "  ANDROID_SERIAL=<serial> $0"
        printf '%s\n' "$devices" | sed 's/^/  /'
        exit 0
    fi
    serial=$devices
fi

# The APK contains only arm64 code; x86 emulators cannot install it.
abis=$("$adb" -s "$serial" shell getprop ro.product.cpu.abilist | tr -d '\r')
if [[ ",$abis," != *",arm64-v8a,"* ]]; then
    echo "Note: device $serial does not support arm64-v8a ($abis); installation skipped."
    exit 0
fi

echo "Installing on $serial …"
if ! output=$("$adb" -s "$serial" install -r "$apk" 2>&1); then
    echo "$output" >&2
    if [[ "$output" == *INSTALL_FAILED_UPDATE_INCOMPATIBLE* ]]; then
        echo >&2
        echo "didscout_app is installed with a different signing key (e.g. a debug build)." >&2
        echo "Uninstall it on the device before installing this build." >&2
    elif [[ "$output" == *INSTALL_FAILED_VERSION_DOWNGRADE* ]]; then
        echo >&2
        echo "A newer version is installed on the device. Increase the version ($version)" >&2
        echo "in pubspec.yaml before installing." >&2
    fi
    exit 1
fi
echo "$output" | tail -1
