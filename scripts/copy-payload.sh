#!/bin/bash
# Copy payload/ into the app bundle. Program code ships as code-signed
# .frameworks in the app's Frameworks/ — bare dylibs in the bundle are rejected
# by App Store (ITMS-90171), so each <name>.xcframework's matching slice (a
# <name>.framework) is embedded there. Everything else in payload/ (etc/, data,
# subfolders) mirrors into Resources/BundledDylibs as non-code resources. For
# each xcframework only the slice matching $PLATFORM_NAME is used, so the same
# payload works for device and simulator. Nothing is compiled here.
set -eu

ROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SOURCE_DIR="${PAYLOAD_DIR:-$ROOT/payload}"
BUILT="${TARGET_BUILD_DIR:-$ROOT/.build}"
APP_RES_DIR="$BUILT/${UNLOCALIZED_RESOURCES_FOLDER_PATH:-Resources}"
RES_DIR="$APP_RES_DIR/BundledDylibs"
FW_DIR="$BUILT/${FRAMEWORKS_FOLDER_PATH:-Frameworks}"
PLATFORM="${PLATFORM_NAME:-iphonesimulator}"

codesign_path() {  # path
  if [ "${CODE_SIGNING_ALLOWED:-YES}" = "NO" ]; then
    return
  fi
  identity="${EXPANDED_CODE_SIGN_IDENTITY:-}"
  if [ -z "$identity" ]; then
    identity="-"
  fi
  xcrun codesign --force --sign "$identity" --timestamp=none "$1"
}

# Print the xcframework slice directory matching the target platform.
select_slice() {
  for dir in "$1"/*/; do
    [ -d "$dir" ] || continue
    base="$(basename "$dir")"
    case "$PLATFORM" in
      iphonesimulator) case "$base" in ios-*-simulator) printf '%s' "$dir"; return ;; esac ;;
      iphoneos)        case "$base" in *-simulator) ;; ios-*) printf '%s' "$dir"; return ;; esac ;;
      macosx)          case "$base" in macos-*) printf '%s' "$dir"; return ;; esac ;;
      *)               case "$base" in ios-*-simulator) printf '%s' "$dir"; return ;; esac ;;
    esac
  done
}

mkdir -p "$RES_DIR" "$FW_DIR"
find "$RES_DIR" -mindepth 1 -delete   # our resources dir — safe to wipe

if [ ! -d "$SOURCE_DIR" ]; then
  echo "note: no payload at $SOURCE_DIR — bundling nothing"
  exit 0
fi

# Drop program frameworks that were embedded by an older payload but no longer
# exist in the current payload. Leave Xcode/SwiftPM frameworks alone.
for fw in "$FW_DIR"/*.framework; do
  [ -d "$fw" ] || continue
  name="$(basename "$fw" .framework)"
  base="$name"
  case "$name" in
    *-pool-*) base="${name%%-pool-*}" ;;
  esac
  bundle_id=""
  if [ -f "$fw/Info.plist" ]; then
    bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$fw/Info.plist" 2>/dev/null || true)"
  fi
  case "$bundle_id" in
    jp.takpika.micro-os.prog.*)
      [ -d "$SOURCE_DIR/$base.xcframework" ] || rm -rf "$fw"
      ;;
  esac
done

# 1. Mirror non-code payload files (etc/, data, …) into BundledDylibs. xcframeworks
# (handled below) and bare dylibs (not allowed in the bundle) are excluded.
# --copy-unsafe-links: a payload entry that is a symlink pointing OUTSIDE the
# payload tree (e.g. a local data/ symlinked elsewhere) is copied as the real
# files it refers to — the bundle must be self-contained (code signing/installd
# reject escaping symlinks). In-tree links are left as links.
rsync -a --copy-unsafe-links \
  --exclude='*.xcframework' \
  --exclude='*.dylib' \
  --exclude='PrivacyInfo.xcprivacy' \
  --exclude='.gitignore' \
  --exclude='.gitkeep' \
  --exclude='.DS_Store' \
  --exclude='README.md' \
  "$SOURCE_DIR"/ "$RES_DIR"/

if [ -f "$SOURCE_DIR/PrivacyInfo.xcprivacy" ]; then
  cp "$SOURCE_DIR/PrivacyInfo.xcprivacy" "$APP_RES_DIR/PrivacyInfo.xcprivacy"
fi

# 2. Embed each xcframework's matching slice (a .framework) into Frameworks/, then
# code-sign it. Only our program frameworks are touched (others Xcode may have put
# in Frameworks/ are left alone). chmod +x the binary: dlopen doesn't care, but a
# shell (toybox sh) only runs a PATH command after access(X_OK), and command links
# point at these.
slices=0
shopt -s nullglob
for xcf in "$SOURCE_DIR"/*.xcframework; do
  name="$(basename "$xcf" .xcframework)"
  slice="$(select_slice "$xcf")"
  if [ -z "$slice" ]; then
    echo "warning: $name.xcframework has no slice for $PLATFORM — skipping" >&2
    continue
  fi
  # The framework inside the slice is named after the xcframework. Check the
  # exact path (a glob that matches nothing would expand to nothing and make
  # `ls -d` list ".", which would then copy the whole repo into the bundle).
  fw="$slice$name.framework"
  if [ ! -d "$fw" ]; then
    echo "note: $name.xcframework has no $name.framework slice (stale dylib xcframework?) — skipping" >&2
    continue
  fi
  rm -rf "$FW_DIR/$name.framework"
  cp -R "$fw" "$FW_DIR/$name.framework"
  bin="$FW_DIR/$name.framework/$name"
  [ -f "$bin" ] && chmod +x "$bin"
  codesign_path "$FW_DIR/$name.framework"
  slices=$((slices + 1))
done

echo "payload -> $slices framework(s) embedded in Frameworks/ for $PLATFORM"

# 3. Pooled programs. A multicall program that spawns instances of *itself* (the
# toybox shell forks children that are also toybox) needs each live instance to
# have its own copy of the image's globals (toys/this/toybuf). On the simulator
# the loader gets that by dlopen'ing a private copy in a temp dir; on a real
# device code signing forbids executing any image outside the signed app bundle,
# so instead we ship extra signed copies here and the loader hands one out per
# instance (each a distinct realpath -> distinct dyld image -> distinct __DATA).
# Single-instance programs (init, wm, the apps) never collide and get no pool.
POOL_PROGRAMS="${POOL_PROGRAMS:-toybox}"
POOL_SIZE="${POOL_SIZE:-16}"
for name in $POOL_PROGRAMS; do
  src="$FW_DIR/$name.framework"
  rm -rf "$FW_DIR/$name-pool-"*.framework   # drop stale copies from a prior build
  [ -d "$src" ] || continue
  for i in $(seq 1 "$POOL_SIZE"); do
    dst="$FW_DIR/$name-pool-$i.framework"
    cp -R "$src" "$dst"
    # Unique bundle id per copy so App Store validation sees no duplicate ids.
    plist="$dst/Info.plist"
    if [ -f "$plist" ]; then
      /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier jp.takpika.micro-os.prog.$name.pool$i" "$plist" \
        || plutil -replace CFBundleIdentifier -string "jp.takpika.micro-os.prog.$name.pool$i" "$plist" || true
    fi
    codesign_path "$dst"
  done
  echo "pool -> $name x$POOL_SIZE signed copies for per-instance isolation on device"
done
