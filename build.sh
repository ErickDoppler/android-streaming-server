#!/bin/sh
# ============================================================================
#  build.sh - builds android-streaming-server on Linux and macOS.
#
#  "Building" here means
#
#    1. find the toolchain (tools/ first, then this machine's JDK / SDK)
#    2. check every source file the APK needs is present
#    3. run the Gradle build
#    4. verify the APK really contains the manifest, the dex and the
#       viewer page - a Gradle "BUILD SUCCESSFUL" alone is not proof
#    5. stage a runnable dist/ with the installable APK in it
#
#    ./build.sh                 debug APK - signed with the local debug key,
#                               so it installs straight onto a device
#    ./build.sh --release       release APK - smaller, but UNSIGNED, so it
#                               will not install until you sign it yourself
#    ./build.sh --clean         wipe build outputs first
#    ./build.sh --install       adb-install the result onto the one attached
#                               device when the build succeeds
#
#  Run ./download-tools.sh once before the first build.
# ============================================================================
set -eu
cd "$(dirname "$0")"

JDK_FEATURE=17          # AGP 8.7.3 needs >= 17; Gradle 8.11.1 supports <= 23
JDK_MAX=23
ANDROID_PLATFORM=35
BUILD_TOOLS=35.0.0

TOOLS="$PWD/tools"
DIST="$PWD/dist"
VARIANT=debug
DO_CLEAN=
DO_INSTALL=

for arg in "$@"; do
  case "$arg" in
    --release) VARIANT=release ;;
    --debug) VARIANT=debug ;;
    --clean) DO_CLEAN=1 ;;
    --install) DO_INSTALL=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

die() {
  echo
  echo "BUILD FAILED" >&2
  exit 1
}

java_major() {
  "$1" -version 2>&1 | head -n 1 | sed -n 's/.*version "\([0-9][0-9]*\).*/\1/p'
}

echo "=== android-streaming-server : build ($VARIANT) ==="
echo

# ------------------------------------------------------- [1/5] the toolchain
echo "[1/5] locating the toolchain ..."

JAVA=
for cand in "$TOOLS/jdk/bin/java" "${JAVA_HOME:-}/bin/java" \
            "$(command -v java 2>/dev/null || true)"; do
  [ -n "$cand" ] && [ -x "$cand" ] || continue
  M="$(java_major "$cand")"
  case "$M" in '' | *[!0-9]*) continue ;; esac
  if [ "$M" -ge "$JDK_FEATURE" ] && [ "$M" -le "$JDK_MAX" ]; then
    JAVA="$cand"
    JAVA_MAJOR="$M"
    break
  fi
done
if [ -z "$JAVA" ]; then
  echo
  echo "[FAIL] no usable JDK found (need $JDK_FEATURE..$JDK_MAX:" >&2
  echo "       the Android plugin needs $JDK_FEATURE+, Gradle 8.11.1 refuses" >&2
  echo "       to run on anything newer than $JDK_MAX)." >&2
  echo "       Run  ./download-tools.sh  to fetch a private JDK $JDK_FEATURE." >&2
  die
fi
JAVA_HOME="$(cd "$(dirname "$JAVA")/.." && pwd)"
export JAVA_HOME
echo "      JDK $JAVA_MAJOR  ($JAVA_HOME)"

has_sdk() {
  [ -n "${1:-}" ] && [ -d "$1/platforms/android-$ANDROID_PLATFORM" ] \
    && [ -d "$1/build-tools/$BUILD_TOOLS" ]
}

SDK=
LOCAL_SDK=
if [ -f local.properties ]; then
  LOCAL_SDK="$(sed -n 's/^sdk\.dir=//p' local.properties | head -n 1 \
               | sed 's/\\\\/\//g; s/\\:/:/g')"
fi
for cand in "$TOOLS/android-sdk" "$LOCAL_SDK" "${ANDROID_HOME:-}" \
            "${ANDROID_SDK_ROOT:-}" "$HOME/Android/Sdk" \
            "$HOME/Library/Android/sdk"; do
  if has_sdk "$cand"; then SDK="$cand"; break; fi
done
if [ -z "$SDK" ]; then
  echo
  echo "[FAIL] no Android SDK with platform android-$ANDROID_PLATFORM and" >&2
  echo "       build-tools $BUILD_TOOLS was found." >&2
  echo "       Run  ./download-tools.sh  to fetch one into tools/." >&2
  die
fi
# Gradle reads the SDK path from local.properties, so keep it in sync.
printf 'sdk.dir=%s\n' "$SDK" > local.properties
export ANDROID_HOME="$SDK"
export ANDROID_SDK_ROOT="$SDK"
echo "      Android SDK  ($SDK)"

# -------------------------------------------------------- [2/5] the sources
echo "[2/5] checking sources ..."
MISSING=
for f in settings.gradle.kts build.gradle.kts app/build.gradle.kts \
         app/src/main/AndroidManifest.xml \
         app/src/main/assets/index.html \
         app/src/main/java/com/example/streamserver/MainActivity.kt \
         app/src/main/java/com/example/streamserver/StreamRelay.kt \
         app/src/main/java/com/example/streamserver/StreamPlayerView.kt; do
  [ -f "$f" ] || MISSING="$MISSING $f"
done
if [ -n "$MISSING" ]; then
  echo "[FAIL] missing source file(s):$MISSING" >&2
  die
fi
VERSION="$(sed -n 's/.*versionName *= *"\([^"]*\)".*/\1/p' app/build.gradle.kts \
           | head -n 1)"
[ -n "$VERSION" ] || VERSION=0
MIN_SDK="$(sed -n 's/.*minSdk *= *\([0-9]*\).*/\1/p' app/build.gradle.kts | head -n 1)"
echo "      Streaming Server v$VERSION  (minSdk $MIN_SDK, compileSdk $ANDROID_PLATFORM)"

# ---------------------------------------------------------- [3/5] the build
chmod +x ./gradlew 2>/dev/null || true
if [ -n "$DO_CLEAN" ]; then
  echo "[3/5] cleaning, then building ..."
  ./gradlew --console=plain clean || die
else
  echo "[3/5] building ..."
fi
if [ "$VARIANT" = release ]; then
  ./gradlew --console=plain assembleRelease || die
  APK="$(ls app/build/outputs/apk/release/*.apk 2>/dev/null | head -n 1 || true)"
else
  ./gradlew --console=plain assembleDebug || die
  APK="app/build/outputs/apk/debug/app-debug.apk"
fi
if [ ! -f "$APK" ]; then
  echo "[FAIL] Gradle reported success but produced no APK." >&2
  die
fi

# -------------------------------------------------------- [4/5] verify it
echo "[4/5] verifying the APK ..."
LIST="$("$JAVA_HOME/bin/jar" tf "$APK" 2>/dev/null || true)"
for entry in AndroidManifest.xml classes.dex assets/index.html; do
  case "
$LIST" in
    *"
$entry"*) ;;
    *)
      echo "[FAIL] $APK has no $entry - the package is not usable." >&2
      die
      ;;
  esac
done
echo "      manifest + dex + viewer page present"

# --------------------------------------------------------- [5/5] stage dist
echo "[5/5] staging dist/ ..."
rm -rf "$DIST"
mkdir -p "$DIST"
if [ "$VARIANT" = release ]; then
  OUT="$DIST/streaming-server-$VERSION-release-unsigned.apk"
else
  OUT="$DIST/streaming-server-$VERSION-debug.apk"
fi
cp "$APK" "$OUT"
if [ -f readme.md ]; then cp readme.md "$DIST/README.md"; fi
if [ -f LICENSE ]; then cp LICENSE "$DIST/LICENSE"; fi

SIZE="$(ls -l "$OUT" | awk '{printf "%.1f", $5 / 1048576}')"

# ----------------------------------------------------------------- install
ADB="$SDK/platform-tools/adb"
if [ ! -x "$ADB" ]; then ADB="$(command -v adb 2>/dev/null || true)"; fi
if [ -n "$DO_INSTALL" ]; then
  if [ "$VARIANT" = release ]; then
    echo
    echo "[FAIL] the release APK is unsigned and cannot be installed." >&2
    echo "       Sign it first, or build without --release." >&2
    die
  fi
  if [ -z "$ADB" ]; then
    echo
    echo "[FAIL] adb not found - cannot --install." >&2
    die
  fi
  echo
  echo "installing on the attached device ..."
  "$ADB" install -r "$OUT" || die
  "$ADB" shell am start -n com.example.streamserver/.MainActivity >/dev/null || true
  echo "started com.example.streamserver on the device"
fi

echo
echo "BUILD OK"
echo
echo "  APK:  $OUT  (${SIZE} MB)"
echo
if [ "$VARIANT" = release ]; then
  echo "  This release APK is UNSIGNED. Sign it before installing:"
  echo "    $SDK/build-tools/$BUILD_TOOLS/apksigner sign \\"
  echo "        --ks my.jks --out streaming-server.apk \"$OUT\""
else
  echo "  Install it:   ${ADB:-adb} install -r \"$OUT\""
  echo "  Or copy the APK to the device and tap it."
fi
echo
echo "  Once running, the app prints the one TCP port it serves on. Publishers"
echo "  connect to  <device-ip>:<port>  and viewers open  http://<device-ip>:<port>"
echo
