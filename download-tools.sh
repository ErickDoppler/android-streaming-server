#!/bin/sh
# ============================================================================
#  download-tools.sh - fetches every tool needed to build this project on
#  Linux and macOS.
#
#  Building the APK needs three things, and this script provides all of them
#  without touching the system: nothing is installed system-wide, no sudo, no
#  package manager, no Android Studio.
#
#    1. a JDK 17        -> tools/jdk          (Eclipse Temurin, portable)
#    2. the Android SDK -> tools/android-sdk  (command-line tools only:
#       platform-tools + platforms;android-35 + build-tools;35.0.0)
#    3. Gradle 8.11.1   -> fetched by ./gradlew itself, into ~/.gradle
#
#  It also writes local.properties, so ./build.sh finds the SDK afterwards.
#
#    ./download-tools.sh          reuse a usable JDK / SDK already on this
#                                 machine, download only what is missing
#    ./download-tools.sh --force  ignore what is installed and download
#                                 private copies into tools/
#
#  Downloads come from api.adoptium.net and dl.google.com over HTTPS and are
#  verified against the checksums those projects publish.
# ============================================================================
set -eu
cd "$(dirname "$0")"

JDK_FEATURE=17          # AGP 8.7.3 needs >= 17; Gradle 8.11.1 supports <= 23
JDK_MAX=23
ANDROID_PLATFORM=35
BUILD_TOOLS=35.0.0
CMDLINE_TOOLS_BUILD=11076708

TOOLS="$PWD/tools"
JDK_HOME="$TOOLS/jdk"
SDK_HOME="$TOOLS/android-sdk"
DL="$TOOLS/download"

FORCE=
case "${1:-}" in
  --force | -f) FORCE=1 ;;
  '') ;;
  *) echo "unknown option: $1" >&2; exit 2 ;;
esac

echo "=== android-streaming-server : download-tools ==="
echo

# ------------------------------------------------------------------ helpers

fetch() { # fetch <url> <destination>
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --proto '=https' -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget --https-only -O "$2" "$1"
  else
    echo "[FAIL] neither curl nor wget is available - cannot download." >&2
    exit 1
  fi
}

# java_major <path to java> - prints the feature version, or nothing.
java_major() {
  "$1" -version 2>&1 | head -n 1 | sed -n 's/.*version "\([0-9][0-9]*\).*/\1/p'
}

sha_of() { # sha_of <256|1> <file>
  if [ "$1" = 256 ]; then
    if command -v sha256sum >/dev/null 2>&1; then
      sha256sum "$2" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
      shasum -a 256 "$2" | cut -d' ' -f1
    fi
  else
    if command -v sha1sum >/dev/null 2>&1; then
      sha1sum "$2" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
      shasum -a 1 "$2" | cut -d' ' -f1
    fi
  fi
}

# ------------------------------------------------------------- this platform
case "$(uname -s)" in
  Linux)  ADOPT_OS=linux; SDK_OS=linux ;;
  Darwin) ADOPT_OS=mac;   SDK_OS=mac ;;
  *)
    echo "[FAIL] unsupported OS: $(uname -s) - use download-tools.cmd on Windows." >&2
    exit 1
    ;;
esac
case "$(uname -m)" in
  x86_64 | amd64)  ADOPT_ARCH=x64 ;;
  aarch64 | arm64) ADOPT_ARCH=aarch64 ;;
  *)
    echo "[FAIL] unsupported CPU: $(uname -m)." >&2
    echo "       Install a JDK $JDK_FEATURE yourself and re-run with JAVA_HOME set." >&2
    exit 1
    ;;
esac

# SHA-1 of commandlinetools-<os>-11076708_latest.zip, as published by Google
# in https://dl.google.com/android/repository/repository2-3.xml
if [ "$SDK_OS" = linux ]; then
  CMDLINE_SHA1=d313adb7aedccf6cf0cfca51ec180f0059f5f8f8
else
  CMDLINE_SHA1=37fb7dd41005b3b4ca6ea48ac27074b6fc4e3236
fi

# ================================================================== [1/3] JDK
echo "[1/3] JDK $JDK_FEATURE"

JAVA=
if [ -z "$FORCE" ] && [ -x "$JDK_HOME/bin/java" ]; then
  JAVA="$JDK_HOME/bin/java"
  echo "[ok]   private JDK $(java_major "$JAVA") already in tools/jdk"
elif [ -z "$FORCE" ]; then
  # A JDK already on this machine is fine if Gradle 8.11.1 can run on it.
  SYSJAVA="$(command -v java 2>/dev/null || true)"
  for cand in "${JAVA_HOME:-}/bin/java" "$SYSJAVA"; do
    [ -n "$cand" ] && [ -x "$cand" ] || continue
    M="$(java_major "$cand")"
    case "$M" in '' | *[!0-9]*) continue ;; esac
    if [ "$M" -ge "$JDK_FEATURE" ] && [ "$M" -le "$JDK_MAX" ]; then
      JAVA="$cand"
      echo "[ok]   JDK $M found at $cand - usable, no download needed"
      echo "       (run \"./download-tools.sh --force\" for a private copy anyway)"
      break
    fi
    echo "[..]   JDK $M at $cand is outside the supported range $JDK_FEATURE..$JDK_MAX"
  done
fi

if [ -z "$JAVA" ]; then
  echo "[..]   resolving the latest Temurin $JDK_FEATURE for $ADOPT_OS-$ADOPT_ARCH ..."
  mkdir -p "$DL"
  API="https://api.adoptium.net/v3/assets/latest/$JDK_FEATURE/hotspot"
  API="$API?os=$ADOPT_OS&architecture=$ADOPT_ARCH&image_type=jdk&vendor=eclipse"
  fetch "$API" "$DL/jdk.json"
  # Only the archive matches - the .pkg/.msi installers end differently.
  JDK_URL="$(tr ',' '\n' < "$DL/jdk.json" \
             | grep -o '"link":[ ]*"[^"]*-jdk_[^"]*\.tar\.gz"' \
             | head -n 1 | sed 's/.*"\(https[^"]*\)"$/\1/')"
  if [ -z "$JDK_URL" ]; then
    echo "[FAIL] api.adoptium.net offered no JDK $JDK_FEATURE build for" >&2
    echo "       $ADOPT_OS-$ADOPT_ARCH. Install one yourself and set JAVA_HOME." >&2
    exit 1
  fi
  JDK_FILE="$DL/$(basename "$JDK_URL")"
  echo "[..]   downloading $(basename "$JDK_URL") (~190 MB) ..."
  fetch "$JDK_URL" "$JDK_FILE"

  echo "[..]   verifying SHA-256 ..."
  fetch "$JDK_URL.sha256.txt" "$JDK_FILE.sha256.txt"
  WANT="$(cut -d' ' -f1 < "$JDK_FILE.sha256.txt")"
  GOT="$(sha_of 256 "$JDK_FILE")"
  if [ -z "$GOT" ]; then
    echo "[warn] no sha256sum/shasum available - skipping checksum verification"
  elif [ "$WANT" != "$GOT" ]; then
    echo "[FAIL] SHA-256 of the JDK archive does not match Adoptium's." >&2
    echo "       want $WANT" >&2
    echo "       got  $GOT" >&2
    rm -f "$JDK_FILE"
    exit 1
  else
    echo "[ok]   checksum matches Adoptium's published SHA-256"
  fi

  echo "[..]   unpacking ..."
  rm -rf "$DL/jdk-unpack"
  mkdir -p "$DL/jdk-unpack"
  tar -xzf "$JDK_FILE" -C "$DL/jdk-unpack"
  # Linux tarballs hold <root>/bin/java, macOS ones <root>/Contents/Home/bin/java.
  SRC="$(dirname "$(find "$DL/jdk-unpack" -type f -name javac -path '*/bin/javac' \
         | head -n 1)")"
  SRC="${SRC%/bin}"
  if [ ! -x "$SRC/bin/java" ]; then
    echo "[FAIL] could not find bin/java inside the JDK archive." >&2
    exit 1
  fi
  rm -rf "$JDK_HOME"
  mkdir -p "$TOOLS"
  mv "$SRC" "$JDK_HOME"
  JAVA="$JDK_HOME/bin/java"
  echo "[ok]   private JDK $(java_major "$JAVA") installed in tools/jdk"
fi

JAVA_HOME="$(cd "$(dirname "$JAVA")/.." && pwd)"
export JAVA_HOME
echo

# ========================================================== [2/3] Android SDK
echo "[2/3] Android SDK (platform $ANDROID_PLATFORM, build-tools $BUILD_TOOLS)"

# has_sdk <dir> - true when that SDK can already build this project.
has_sdk() {
  [ -n "${1:-}" ] && [ -d "$1/platforms/android-$ANDROID_PLATFORM" ] \
    && [ -d "$1/build-tools/$BUILD_TOOLS" ]
}

SDK=
if [ -z "$FORCE" ]; then
  for cand in "$SDK_HOME" "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" \
              "$HOME/Android/Sdk" "$HOME/Library/Android/sdk"; do
    if has_sdk "$cand"; then
      SDK="$cand"
      echo "[ok]   usable Android SDK found at $SDK"
      break
    fi
  done
fi

if [ -z "$SDK" ]; then
  SDK="$SDK_HOME"
  SDKMANAGER="$SDK/cmdline-tools/latest/bin/sdkmanager"
  if [ ! -x "$SDKMANAGER" ] || [ -n "$FORCE" ]; then
    ZIP="commandlinetools-$SDK_OS-${CMDLINE_TOOLS_BUILD}_latest.zip"
    echo "[..]   downloading the Android command-line tools ($SDK_OS) ..."
    mkdir -p "$DL"
    fetch "https://dl.google.com/android/repository/$ZIP" "$DL/$ZIP"

    echo "[..]   verifying SHA-1 ..."
    GOT="$(sha_of 1 "$DL/$ZIP")"
    if [ -z "$GOT" ]; then
      echo "[warn] no sha1sum/shasum available - skipping checksum verification"
    elif [ "$GOT" != "$CMDLINE_SHA1" ]; then
      echo "[FAIL] SHA-1 of $ZIP does not match Google's repository manifest." >&2
      echo "       want $CMDLINE_SHA1" >&2
      echo "       got  $GOT" >&2
      rm -f "$DL/$ZIP"
      exit 1
    else
      echo "[ok]   checksum matches Google's repository manifest"
    fi

    echo "[..]   unpacking ..."
    rm -rf "$DL/cmdline-unpack"
    mkdir -p "$DL/cmdline-unpack"
    if command -v unzip >/dev/null 2>&1; then
      unzip -q "$DL/$ZIP" -d "$DL/cmdline-unpack"
    else
      # bsdtar (macOS, and most Linux boxes) reads zip files too.
      tar -xf "$DL/$ZIP" -C "$DL/cmdline-unpack"
    fi
    # sdkmanager insists on living in cmdline-tools/<channel>/.
    rm -rf "$SDK/cmdline-tools"
    mkdir -p "$SDK/cmdline-tools"
    mv "$DL/cmdline-unpack/cmdline-tools" "$SDK/cmdline-tools/latest"
    chmod +x "$SDK"/cmdline-tools/latest/bin/* 2>/dev/null || true
    if [ ! -x "$SDKMANAGER" ]; then
      echo "[FAIL] sdkmanager is missing after unpacking $ZIP." >&2
      exit 1
    fi
    echo "[ok]   command-line tools installed in tools/android-sdk"
  else
    echo "[ok]   command-line tools already in tools/android-sdk"
  fi

  # sdkmanager asks "Accept? (y/N)" once per licence and reads plain stdin.
  echo "[..]   accepting the SDK licences ..."
  yes | "$SDKMANAGER" --sdk_root="$SDK" --licenses >/dev/null 2>&1 || true
  if [ ! -f "$SDK/licenses/android-sdk-license" ]; then
    echo "[FAIL] the Android SDK licences were not accepted, so nothing can be" >&2
    echo "       installed. Accept them by hand with:" >&2
    echo "         $SDKMANAGER --sdk_root=\"$SDK\" --licenses" >&2
    exit 1
  fi

  echo "[..]   installing platform-tools, platforms;android-$ANDROID_PLATFORM and"
  echo "       build-tools;$BUILD_TOOLS  (a few hundred MB, please wait) ..."
  if ! yes | "$SDKMANAGER" --sdk_root="$SDK" \
       "platform-tools" \
       "platforms;android-$ANDROID_PLATFORM" \
       "build-tools;$BUILD_TOOLS"; then
    echo "[FAIL] sdkmanager could not install the SDK packages." >&2
    exit 1
  fi
  if ! has_sdk "$SDK"; then
    echo "[FAIL] the SDK packages are still missing after sdkmanager ran." >&2
    exit 1
  fi
  echo "[ok]   Android SDK ready in tools/android-sdk"
fi
echo

# ============================================ [3/3] local.properties + Gradle
echo "[3/3] wiring the build"

# local.properties is machine-local and git-ignored: it is how Gradle finds
# the SDK. It is rewritten on every run, so a moved tools/ keeps working.
printf 'sdk.dir=%s\n' "$SDK" > local.properties
echo "[ok]   local.properties -> sdk.dir=$SDK"

chmod +x ./gradlew 2>/dev/null || true
echo "[..]   priming the Gradle wrapper (downloads Gradle on the first run) ..."
if GRADLE_VER="$(./gradlew --version 2>/dev/null | sed -n 's/^Gradle *//p' | head -n 1)"
then
  echo "[ok]   Gradle $GRADLE_VER is ready"
else
  echo "[warn] could not run ./gradlew now - it will fetch Gradle during the"
  echo "       first build instead."
fi

rm -rf "$DL"

echo
echo "All build tools are in place."
echo
echo "  JDK          $JAVA_HOME"
echo "  Android SDK  $SDK"
echo
echo "Next:  ./build.sh"
echo
