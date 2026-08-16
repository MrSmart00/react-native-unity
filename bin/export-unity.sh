#!/usr/bin/env bash
#
# Exports a Unity project into the shape @mrsmart00/react-native-unity expects, and
# puts the package's Unity-side sources into that project.
#
# Run it from the Expo app directory:
#
#   npx react-native-unity-export            # ios + android
#   npx react-native-unity-export ios
#   npx react-native-unity-export android
#
# The app declares where its Unity project is, in its own package.json:
#
#   "unityEmbed": { "project": "../unity/game" }
#
# Outputs land in <app>/unity/builds/{ios,android}/ — owned by the app, not by
# this package, because they are that app's game rather than anything shared.
#
# ── Why this exists rather than a page of instructions ─────────────────────
#
# The export is where an embedding silently goes stale: a previous
# UnityFramework or unityLibrary still builds, still launches, and still runs —
# just not the code you edited. Every step below either deletes before writing,
# or prints something you can check against what actually shipped.
set -euo pipefail

APP="$PWD"

# ⚠️ Resolve the symlink before deriving the package root.
#
# npm exposes this as node_modules/.bin/react-native-unity-export, a symlink. Taking
# dirname of BASH_SOURCE there lands in node_modules/ rather than in the package,
# and the first thing that fails is a `cp` from a path that does not exist.
# `readlink -f` is not portable to every macOS in use, hence the loop.
SELF="${BASH_SOURCE[0]}"
while [ -L "$SELF" ]; do
  TARGET="$(readlink "$SELF")"
  case "$TARGET" in
    /*) SELF="$TARGET" ;;
    *)  SELF="$(dirname "$SELF")/$TARGET" ;;
  esac
done
PKG="$(cd "$(dirname "$SELF")/.." && pwd)"

OUT="$APP/unity/builds"

if [[ ! -f "$APP/package.json" ]]; then
  echo "Run this from the Expo app directory (no package.json here)." >&2
  exit 1
fi

PROJECT_REL="$(node -e 'const p=require(process.argv[1]);process.stdout.write((p.unityEmbed&&p.unityEmbed.project)||"")' "$APP/package.json")"
if [[ -z "$PROJECT_REL" ]]; then
  echo "package.json has no \"unityEmbed\": { \"project\": \"<path to Unity project>\" }." >&2
  exit 1
fi
PROJECT="$(cd "$APP/$PROJECT_REL" 2>/dev/null && pwd || true)"
if [[ -z "$PROJECT" || ! -d "$PROJECT/Assets" ]]; then
  echo "unityEmbed.project points at '$PROJECT_REL', which is not a Unity project." >&2
  exit 1
fi

# ── Unity version ──────────────────────────────────────────────────────────
# Read from the project rather than "whatever is installed": Unity rewrites
# ProjectSettings on open, so a different Editor silently upgrades the project
# for everyone else.
VERSION="$(sed -n 's/^m_EditorVersion: //p' "$PROJECT/ProjectSettings/ProjectVersion.txt")"
UNITY="/Applications/Unity/Hub/Editor/$VERSION/Unity.app/Contents/MacOS/Unity"
if [[ ! -x "$UNITY" ]]; then
  echo "Unity $VERSION is not installed at $UNITY" >&2
  echo "Install it with:" >&2
  echo "  '/Applications/Unity Hub.app/Contents/MacOS/Unity Hub' -- --headless install \\" >&2
  echo "     --version $VERSION -a arm64 -m ios android --childModules" >&2
  echo >&2
  echo "The Editor still needs a licence before it will launch, and activating a" >&2
  echo "Personal licence requires signing in through the Unity Hub GUI — there is" >&2
  echo "no headless path for it. That is the one manual step in this pipeline." >&2
  exit 1
fi

run_unity() {
  local method="$1" log="$2"
  echo "→ Unity $VERSION: $method"
  # -nographics is safe: nothing in the build script renders, and it keeps the
  # build runnable over ssh / in CI.
  if ! "$UNITY" -batchmode -nographics -quit \
      -projectPath "$PROJECT" -executeMethod "$method" -logFile "$log"; then
    echo "Unity build failed. Last 40 lines of $log:" >&2
    tail -40 "$log" >&2
    exit 1
  fi
}

uuid_of() { dwarfdump --uuid "$1" 2>/dev/null | awk '{print $2}'; }

# ── Keep the Unity project's copies in step with this package ──────────────
#
# ⚠️ The C function name in UnityEmbedNativeCalls.mm and the DllImport in
# UnityEmbedNative.cs are one contract; the Kotlin class name and the
# AndroidJavaClass string are another. Neither is checked by any compiler, and
# both break silently — the app builds, runs, renders, and never delivers a
# message. Re-copying on every export is what keeps a stale copy in the Unity
# project from becoming that failure.
sync_sources() {
  local changed=0
  copy_if_changed() {
    local src="$1" dst="$2"
    mkdir -p "$(dirname "$dst")"
    if [[ ! -f "$dst" ]] || ! cmp -s "$src" "$dst"; then
      cp "$src" "$dst"
      echo "  updated ${dst#"$PROJECT/"}"
      changed=1
    fi
  }

  copy_if_changed "$PKG/unity/Plugins/iOS/UnityEmbedNativeCalls.h"  "$PROJECT/Assets/Plugins/iOS/UnityEmbedNativeCalls.h"
  copy_if_changed "$PKG/unity/Plugins/iOS/UnityEmbedNativeCalls.mm" "$PROJECT/Assets/Plugins/iOS/UnityEmbedNativeCalls.mm"
  copy_if_changed "$PKG/unity/Scripts/UnityEmbedNative.cs"          "$PROJECT/Assets/UnityEmbed/UnityEmbedNative.cs"

  if [[ $changed -eq 1 ]]; then
    echo "→ synced @mrsmart00/react-native-unity sources into the Unity project"
  fi
}

# ── iOS ────────────────────────────────────────────────────────────────────
build_ios() {
  sync_sources
  run_unity BuildScript.IOSDevice    "$PROJECT/build/ios-device.log"
  run_unity BuildScript.IOSSimulator "$PROJECT/build/ios-simulator.log"

  local work="$PROJECT/build/xcframework"
  rm -rf "$work" "$OUT/ios"
  mkdir -p "$work" "$OUT/ios"

  # Two builds on purpose. UnityFramework as Unity emits it is device-only and
  # will not link against the simulator. The App Store build is unaffected:
  # Xcode links only the device slice out of an xcframework.
  #
  # CODE_SIGNING_ALLOWED=NO so this works without a paid team; the framework is
  # re-signed when the host app is built.
  xcodebuild -project "$PROJECT/build/ios-device/Unity-iPhone.xcodeproj" \
    -scheme UnityFramework -configuration Release -sdk iphoneos \
    BUILD_DIR="$work/device" CODE_SIGNING_ALLOWED=NO build >"$work/device.log" 2>&1 \
    || { tail -40 "$work/device.log" >&2; exit 1; }

  xcodebuild -project "$PROJECT/build/ios-simulator/Unity-iPhone.xcodeproj" \
    -scheme UnityFramework -configuration Release -sdk iphonesimulator \
    BUILD_DIR="$work/sim" CODE_SIGNING_ALLOWED=NO build >"$work/sim.log" 2>&1 \
    || { tail -40 "$work/sim.log" >&2; exit 1; }

  xcodebuild -create-xcframework \
    -framework "$work/device/Release-iphoneos/UnityFramework.framework" \
    -framework "$work/sim/Release-iphonesimulator/UnityFramework.framework" \
    -output "$OUT/ios/UnityFramework.xcframework"

  echo
  echo "iOS → unity/builds/ios/UnityFramework.xcframework"
  for slice in "$OUT/ios/UnityFramework.xcframework"/*/; do
    local bin="$slice/UnityFramework.framework/UnityFramework"
    [[ -f "$bin" ]] || continue
    printf '  %-28s %8s  uuid:%s\n' \
      "$(basename "$slice")" "$(du -h "$bin" | cut -f1)" "$(uuid_of "$bin")"
  done

  if [[ ! -d "$OUT/ios/UnityFramework.xcframework/ios-arm64-simulator" ]]; then
    echo >&2
    echo "  ⚠️  no ios-arm64-simulator slice. Unity defaults the Simulator SDK to" >&2
    echo "      x86_64, which cannot run on an Apple Silicon Mac — recent Xcode has" >&2
    echo "      no Rosetta simulator. Check simulatorSdkArchitecture in the project's" >&2
    echo "      build script." >&2
  fi

  stage_into_pod
  refresh_pods
}

# ── Put the framework where CocoaPods can see it ───────────────────────────
#
# `vendored_frameworks` is resolved against the pod root and will not follow a
# path outside it, so the app-owned framework has to be staged into the
# installed package.
#
# ⚠️ Done here rather than with a podspec `prepare_command`. CocoaPods runs
# prepare_command when it downloads a pod's source; for a pod referenced by
# :path — which is every npm-installed Expo module — it does not run on
# subsequent installs, and the pod ends up with no vendor/ directory at all.
#
# Resolved through Node rather than assumed, so this works whether the package
# was installed plainly, linked with `file:`, or hoisted by a workspace.
stage_into_pod() {
  local installed
  installed="$(node -e "
    const {createRequire} = require('module');
    const r = createRequire(process.argv[1] + '/');
    console.log(require('path').dirname(r.resolve('@mrsmart00/react-native-unity/package.json')));
  " "$APP" 2>/dev/null || true)"

  if [[ -z "$installed" ]]; then
    echo "could not resolve @mrsmart00/react-native-unity from $APP — is it installed?" >&2
    exit 1
  fi

  rm -rf "$installed/ios/vendor"
  mkdir -p "$installed/ios/vendor"
  cp -R "$OUT/ios/UnityFramework.xcframework" "$installed/ios/vendor/"
  echo "  staged into ${installed}/ios/vendor"
}

# ── Make the new framework actually reach the app ──────────────────────────
#
# ⚠️ Without this, everything above succeeds and the next build still ships the
# previous engine. Measured: Xcode runs `[CP] Copy XCFrameworks` but skips
# `[CP] Embed Pods Frameworks`, whose input file list does not see the change.
# Nothing warns; the app just runs old code.
#
# To confirm afterwards, compare UUIDs — NOT sha256, which changes when Xcode
# re-signs the framework on embed:
#
#   dwarfdump --uuid "$(xcrun simctl get_app_container booted <bundle-id>)"/\
# Frameworks/UnityFramework.framework/UnityFramework
refresh_pods() {
  if [[ ! -f "$APP/ios/Podfile" ]]; then
    echo
    echo "  ios/ does not exist yet — run \`npx expo prebuild\` next."
    return
  fi

  echo
  echo "→ pod install (so the new framework reaches the app bundle)"
  (cd "$APP" && npx pod-install >/dev/null) \
    || { echo "  pod install failed — run 'npx pod-install' manually" >&2; exit 1; }
}

# ── Android ────────────────────────────────────────────────────────────────
build_android() {
  sync_sources
  run_unity BuildScript.Android "$PROJECT/build/android.log"

  # Unity has moved this around between versions (with and without a
  # productName directory in between), so locate it rather than hardcode it.
  local exported
  exported="$(find "$PROJECT/build/android" -maxdepth 3 -type d -name unityLibrary | head -1)"
  if [[ -z "$exported" ]]; then
    echo "no unityLibrary under $PROJECT/build/android — did the export succeed?" >&2
    find "$PROJECT/build/android" -maxdepth 2 >&2 || true
    exit 1
  fi
  echo "→ exported module: ${exported#"$PROJECT/"}"

  rm -rf "$OUT/android"
  mkdir -p "$OUT/android"
  cp -R "$exported" "$OUT/android/unityLibrary"

  # unityLibrary/build.gradle starts with `apply from: '../shared/*.gradle'`, so
  # the sibling `shared/` directory is part of the module even though every guide
  # only ever mentions unityLibrary. Copying just the module gives:
  #   Could not read script '.../shared/keepUnitySymbols.gradle' as it does not exist.
  local root shared
  root="$(dirname "$exported")"
  shared="$root/shared"
  if [[ -d "$shared" ]]; then
    cp -R "$shared" "$OUT/android/shared"
  else
    echo "no shared/ next to unityLibrary — check whether build.gradle still needs it" >&2
    grep -n "shared/" "$OUT/android/unityLibrary/build.gradle" >&2 || true
  fi

  # unityLibrary/build.gradle reads `unity.*` gradle properties (NDK path, ABI
  # filters, SDK levels, the IL2CPP toolchain location). Unity puts them in the
  # gradle.properties at the *root* of its export, which we do not take — so the
  # module fails at :unityLibrary:buildIl2Cpp with
  #   Could not get unknown property 'unity.androidNdkPath'
  #
  # Extract them next to the module; the config plugin merges them into the
  # host's gradle.properties at prebuild time. Written out rather than committed
  # because several are absolute paths into this machine's Unity install.
  grep -E '^unity\.' "$root/gradle.properties" > "$OUT/android/unity.properties"
  echo "  forwarded $(wc -l < "$OUT/android/unity.properties" | tr -d ' ') unity.* gradle properties"

  # Unity emits a LAUNCHER intent-filter in unityLibrary's manifest. Left in, the
  # merged host manifest gets a second launcher entry and Android shows two icons
  # for one app, one of which starts Unity with no React Native around it.
  python3 - "$OUT/android/unityLibrary/src/main/AndroidManifest.xml" <<'PY'
import re, sys
path = sys.argv[1]
with open(path, encoding='utf-8') as f:
    xml = f.read()
stripped, n = re.subn(r'\s*<intent-filter>.*?</intent-filter>', '', xml, flags=re.S)
if n:
    with open(path, 'w', encoding='utf-8') as f:
        f.write(stripped)
print(f"→ removed {n} intent-filter block(s) from unityLibrary manifest")
PY

  # ── Is this a Unity this package can talk to? ────────────────────────────
  #
  # The Kotlin sources compile directly against UnityPlayerForActivityOrService,
  # which Unity introduced in Unity 6. Older engines only have UnityPlayer, and
  # the failure lands as a Kotlin compile error deep in a Gradle log with nothing
  # naming Unity — an unhelpful place to learn your engine is too old.
  #
  # Checked with unzip rather than javap so this works without a JDK on PATH.
  local classes_jar="$OUT/android/unityLibrary/libs/unity-classes.jar"
  if [[ -f "$classes_jar" ]] && ! unzip -l "$classes_jar" 2>/dev/null \
      | grep -q 'UnityPlayerForActivityOrService\.class'; then
    echo >&2
    echo "  ✗ This Unity does not provide UnityPlayerForActivityOrService." >&2
    echo "    @mrsmart00/react-native-unity requires Unity 6 or newer; it compiles" >&2
    echo "    against that class directly rather than reaching it by reflection." >&2
    echo "    Exported from: $VERSION" >&2
    exit 1
  fi

  echo
  echo "Android → unity/builds/android/unityLibrary"
  local so abis
  for so in "$OUT/android/unityLibrary/src/main/jniLibs"/*/*.so; do
    [[ -f "$so" ]] || continue
    printf '  %-46s %8s\n' \
      "${so#"$OUT/android/unityLibrary/src/main/jniLibs/"}" "$(du -h "$so" | cut -f1)"
  done
  abis="$(ls "$OUT/android/unityLibrary/src/main/jniLibs" 2>/dev/null | tr '\n' ' ')"
  echo "  ABIs: ${abis:-none}"
  case "$abis" in
    *armeabi*|*x86*)
      echo "  ⚠️  more than arm64-v8a was exported — this must agree with" >&2
      echo "      reactNativeArchitectures, which this package's config plugin sets." >&2
      ;;
  esac
}

case "${1:-all}" in
  ios)     build_ios ;;
  android) build_android ;;
  all)     build_ios; build_android ;;
  *)       echo "usage: react-native-unity-export [ios|android|all]" >&2; exit 2 ;;
esac
