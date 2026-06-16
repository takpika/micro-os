#!/bin/bash
# Copy payload/ into the app bundle (Resources/BundledDylibs), preserving
# structure. For each <name>.xcframework, extract ONLY the slice matching the
# target platform ($PLATFORM_NAME) as a flat <name>.dylib — so the same payload
# works for both device and simulator without re-building. Other files (config,
# loose dylibs, subfolders) are mirrored as-is. Nothing is compiled here.
set -eu

ROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SOURCE_DIR="${PAYLOAD_DIR:-$ROOT/payload}"
OUTPUT_DIR="${TARGET_BUILD_DIR:-$ROOT/.build}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:-Resources}/BundledDylibs"
PLATFORM="${PLATFORM_NAME:-iphonesimulator}"

sign_dylib() {
  dylib="$1"
  if [ "${CODE_SIGNING_ALLOWED:-YES}" = "NO" ]; then
    return
  fi
  identity="${EXPANDED_CODE_SIGN_IDENTITY:-}"
  if [ -z "$identity" ]; then
    identity="-"
  fi
  xcrun codesign --force --sign "$identity" --timestamp=none "$dylib"
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

mkdir -p "$OUTPUT_DIR"
find "$OUTPUT_DIR" -mindepth 1 -delete

if [ ! -d "$SOURCE_DIR" ]; then
  echo "note: no payload at $SOURCE_DIR — bundling nothing"
  exit 0
fi

# 1. Mirror everything except xcframeworks (handled below) and repo guards.
# --copy-unsafe-links: a payload entry that is a symlink pointing OUTSIDE the
# payload tree (e.g. a local data/ symlinked to assets kept elsewhere) is copied
# as the real files it refers to. The app bundle must be self-contained — code
# signing and installd reject symlinks that escape it — so this materializes such
# assets into the bundle exactly as they would ship on device. In-tree links are
# left as links.
rsync -a --copy-unsafe-links \
  --exclude='*.xcframework' \
  --exclude='.gitignore' \
  --exclude='.gitkeep' \
  --exclude='.DS_Store' \
  --exclude='README.md' \
  "$SOURCE_DIR"/ "$OUTPUT_DIR"/

# 2. Extract the matching slice from each xcframework as a flat dylib.
slices=0
shopt -s nullglob
for xcf in "$SOURCE_DIR"/*.xcframework; do
  name="$(basename "$xcf" .xcframework)"
  slice="$(select_slice "$xcf")"
  if [ -z "$slice" ]; then
    echo "warning: $name.xcframework has no slice for $PLATFORM — skipping" >&2
    continue
  fi
  dylib="$(ls "$slice"*.dylib 2>/dev/null | head -1)"
  if [ -z "$dylib" ]; then
    echo "warning: no dylib inside $slice — skipping $name" >&2
    continue
  fi
  cp "$dylib" "$OUTPUT_DIR/$name.dylib"
  slices=$((slices + 1))
done

# 3. Code-sign every dylib now in the bundle (extracted + any loose ones), and
#    mark it executable: dlopen doesn't care, but a shell (toybox sh) only runs a
#    PATH command after access(X_OK) succeeds, and command links point at these.
signed=0
while IFS= read -r -d '' dylib; do
  chmod +x "$dylib"
  sign_dylib "$dylib"
  signed=$((signed + 1))
done < <(find "$OUTPUT_DIR" -type f -name '*.dylib' -print0)

echo "payload -> BundledDylibs: $slices xcframework slice(s) for $PLATFORM, $signed dylib(s) signed"
