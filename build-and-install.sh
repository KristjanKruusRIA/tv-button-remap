#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

BUILD_ONLY=0
TV_HOST="${TV_HOST:-}"

for arg in "$@"; do
    case "$arg" in
        --build-only)
            BUILD_ONLY=1
            ;;
        -h|--help)
            echo "Usage: TV_HOST=<ip>:<port> $0 [--build-only] | $0 <ip>:<port>"
            exit 0
            ;;
        *)
            if [ -z "$TV_HOST" ]; then
                TV_HOST="$arg"
            else
                echo "Unexpected argument: $arg" >&2
                exit 1
            fi
            ;;
    esac
done

if [ "$BUILD_ONLY" -eq 0 ] && [ -z "$TV_HOST" ]; then
    echo "Error: pass <ip>:<port> or set TV_HOST (or pass --build-only)." >&2
    exit 1
fi

if ! command -v javac >/dev/null 2>&1; then
    echo "Error: javac not found on PATH. Install JDK 17+ or set JAVA_HOME." >&2
    exit 1
fi

SDK_ROOT="${ANDROID_HOME:-$HOME/.android-sdk}"
BT_DIR="$SDK_ROOT/build-tools/34.0.0"
PLAT_DIR="$SDK_ROOT/platforms/android-34"

OS_NAME="$(uname -s)"
case "$OS_NAME" in
    Darwin)
        BT_URL="https://dl.google.com/android/repository/build-tools_r34-macosx.zip"
        ;;
    Linux)
        BT_URL="https://dl.google.com/android/repository/build-tools_r34-linux.zip"
        ;;
    *)
        echo "Unsupported OS: $OS_NAME (use build-and-install.ps1 on Windows)" >&2
        exit 1
        ;;
esac
PLAT_URL="https://dl.google.com/android/repository/platform-34-ext7_r03.zip"

find_tool() {
    local root="$1"
    local name="$2"
    [ -d "$root" ] || return 1
    find "$root" -type f -name "$name" | head -n 1
}

install_sdk_archive() {
    local url="$1"
    local target_dir="$2"
    local marker="$3"
    if find_tool "$target_dir" "$marker" | grep -q .; then
        return 0
    fi
    echo "Downloading $url ..."
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "$tmp_dir"' RETURN
    curl -fsSL "$url" -o "$tmp_dir/archive.zip"
    unzip -q "$tmp_dir/archive.zip" -d "$tmp_dir/extract"
    local found
    found="$(find "$tmp_dir/extract" -type f -name "$marker" | head -n 1)"
    if [ -z "$found" ]; then
        echo "Error: archive from $url did not contain $marker" >&2
        exit 1
    fi
    local src_dir
    src_dir="$(dirname "$found")"
    mkdir -p "$(dirname "$target_dir")"
    rm -rf "$target_dir"
    mv "$src_dir" "$target_dir"
    rm -rf "$tmp_dir"
    trap - RETURN
}

install_sdk_archive "$BT_URL" "$BT_DIR" "aapt2"
install_sdk_archive "$PLAT_URL" "$PLAT_DIR" "android.jar"

AAPT2="$(find_tool "$BT_DIR" "aapt2")"
D8="$(find_tool "$BT_DIR" "d8")"
ZIPALIGN="$(find_tool "$BT_DIR" "zipalign")"
APKSIGNER="$(find_tool "$BT_DIR" "apksigner")"
ANDROID_JAR="$(find_tool "$PLAT_DIR" "android.jar")"

for tool in "$AAPT2" "$D8" "$ZIPALIGN" "$APKSIGNER" "$ANDROID_JAR"; do
    if [ -z "$tool" ]; then
        echo "Error: missing required Android SDK tool under $SDK_ROOT" >&2
        exit 1
    fi
done

BUILD_DIR="$PWD/build"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/gen" "$BUILD_DIR/classes" "$BUILD_DIR/dex"

echo "Compiling resources with aapt2..."
"$AAPT2" compile --dir res -o "$BUILD_DIR/res.zip"
"$AAPT2" link -o "$BUILD_DIR/unaligned.apk" \
    -I "$ANDROID_JAR" \
    --manifest AndroidManifest.xml \
    --java "$BUILD_DIR/gen" \
    --min-sdk-version 26 \
    --target-sdk-version 34 \
    --version-code 1 \
    --version-name 1.0 \
    "$BUILD_DIR/res.zip"

echo "Compiling Java sources..."
mapfile -t JAVA_SOURCES < <(find src "$BUILD_DIR/gen" -type f -name '*.java')
javac -source 11 -target 11 -classpath "$ANDROID_JAR" -d "$BUILD_DIR/classes" "${JAVA_SOURCES[@]}"

echo "Dexing classes with d8..."
mapfile -t CLASS_FILES < <(find "$BUILD_DIR/classes" -type f -name '*.class')
"$D8" --min-api 26 --lib "$ANDROID_JAR" --output "$BUILD_DIR/dex" "${CLASS_FILES[@]}"

echo "Packaging classes.dex into APK..."
jar uf "$BUILD_DIR/unaligned.apk" -C "$BUILD_DIR/dex" classes.dex
"$ZIPALIGN" -f -p 4 "$BUILD_DIR/unaligned.apk" "$BUILD_DIR/aligned.apk"

KEYSTORE="$PWD/local-remap.jks"
if [ ! -f "$KEYSTORE" ]; then
    echo "Generating local signing keystore..."
    keytool -genkeypair -v -keystore "$KEYSTORE" -alias remap -keyalg RSA -keysize 2048 -validity 10000 \
        -storepass android -keypass android -dname "CN=LocalRemap,O=Local,C=US"
fi

APK_OUT="$BUILD_DIR/button-remap.apk"
echo "Signing APK..."
"$APKSIGNER" sign --ks "$KEYSTORE" --ks-pass pass:android --key-pass pass:android \
    --out "$APK_OUT" "$BUILD_DIR/aligned.apk"
"$APKSIGNER" verify "$APK_OUT"

if [ "$BUILD_ONLY" -eq 1 ]; then
    echo "Built and verified: $APK_OUT"
    exit 0
fi

echo "Connecting to $TV_HOST ..."
adb connect "$TV_HOST"
adb -s "$TV_HOST" wait-for-device

echo "Installing APK..."
adb -s "$TV_HOST" install -r "$APK_OUT"

echo "Granting ACCESS_RESTRICTED_SETTINGS and enabling accessibility service..."
adb -s "$TV_HOST" shell appops set com.local.buttonremap ACCESS_RESTRICTED_SETTINGS allow

SVC="com.local.buttonremap/.ButtonRemapService"
FULL_SVC="com.local.buttonremap/com.local.buttonremap.ButtonRemapService"
EXISTING="$(adb -s "$TV_HOST" shell settings get secure enabled_accessibility_services | tr -d '\r\n')"
NEW_VAL="$SVC"
if [ -n "$EXISTING" ] && [ "$EXISTING" != "null" ]; then
    FILTERED=""
    IFS=':' read -ra PARTS <<< "$EXISTING"
    for item in "${PARTS[@]}"; do
        if [ -n "$item" ] && [ "$item" != "$SVC" ] && [ "$item" != "$FULL_SVC" ]; then
            FILTERED="${FILTERED:+$FILTERED:}$item"
        fi
    done
    NEW_VAL="${FILTERED:+$FILTERED:}$SVC"
fi

adb -s "$TV_HOST" shell "settings put secure enabled_accessibility_services '$NEW_VAL'"
adb -s "$TV_HOST" shell "settings put secure accessibility_enabled 1"

echo "Enabled services: $(adb -s "$TV_HOST" shell settings get secure enabled_accessibility_services)"
echo "Accessibility enabled: $(adb -s "$TV_HOST" shell settings get secure accessibility_enabled)"
echo "Done."
