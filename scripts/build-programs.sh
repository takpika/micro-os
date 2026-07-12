#!/bin/bash
# Manual provisioner: build selected programs into payload/ as .xcframeworks.
# Each program is built once per platform (iphoneos + iphonesimulator) and the
# slices are packed into <name>.xcframework. Device and simulator coexist, so
# you never re-build payload when switching targets — the app's build step picks
# the matching slice.
#
#   scripts/build-programs.sh                 # build every program
#   scripts/build-programs.sh init wm         # only these
#   scripts/build-programs.sh --list          # list available programs
#   scripts/build-programs.sh --add-distribution-privacy-manifests
#
# Platforms (default both). Faster sim-only build:
#   PLATFORMS=iphonesimulator scripts/build-programs.sh init
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Autotools configure and CMake break when paths contain spaces (they split
# unquoted $CPPFLAGS / $CMAKE_C_FLAGS on whitespace). Work around this by
# creating a space-free symlink when the project lives under e.g. "iOS Apps".
if [[ "$ROOT" == *" "* ]]; then
  _BUILD_LINK="/tmp/micro-os-build-link"
  ln -sfn "$ROOT" "$_BUILD_LINK"
  _SAFE="$_BUILD_LINK"
else
  _SAFE="$ROOT"
fi

OUT="$_SAFE/payload"
BUILD="$_SAFE/.build/programs"
INCLUDE="$_SAFE/include"
CRT="$_SAFE/crt"
mkdir -p "$OUT" "$BUILD"

PLATFORMS="${PLATFORMS:-iphoneos iphonesimulator}"
CLANG_SDK=()
SWIFT_SDK=()
CURRENT_PLATFORM=""

add_privacy_manifest() {
  local framework="$1"
  local manifest="$framework/PrivacyInfo.xcprivacy"

  if [ ! -d "$framework" ]; then
    echo "warning: privacy manifest target missing: $framework" >&2
    return 0
  fi

  cat > "$manifest" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>NSPrivacyAccessedAPITypes</key>
	<array/>
	<key>NSPrivacyCollectedDataTypes</key>
	<array/>
	<key>NSPrivacyTracking</key>
	<false/>
	<key>NSPrivacyTrackingDomains</key>
	<array/>
</dict>
</plist>
PLIST
}

add_distribution_privacy_manifests() {
  # App Store Connect currently flags these OpenSSL-containing payload frameworks
  # for distribution builds. Keep this as an explicit opt-in so normal local
  # payload builds stay unchanged.
  add_privacy_manifest "$OUT/curl.xcframework/ios-arm64/curl.framework"
  add_privacy_manifest "$OUT/libcrypto.xcframework/ios-arm64/libcrypto.framework"
  add_privacy_manifest "$OUT"
}

set_platform() {
  CURRENT_PLATFORM="$1"
  case "$1" in
    iphoneos)
      sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
      CLANG_SDK=(-isysroot "$sdk" -arch arm64 -miphoneos-version-min=15.0)
      SWIFT_SDK=(-sdk "$sdk" -target arm64-apple-ios15.0)
      ;;
    iphonesimulator)
      sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
      arch="$(uname -m)"
      CLANG_SDK=(-isysroot "$sdk" -arch "$arch" -mios-simulator-version-min=15.0)
      SWIFT_SDK=(-sdk "$sdk" -target "$arch-apple-ios15.0-simulator")
      ;;
    *) echo "unknown platform: $1 (use iphoneos | iphonesimulator)" >&2; exit 1 ;;
  esac
}

sdk_symbol_allowlist() {  # plat
  local plat="$1"
  local cache="$BUILD/sdk-symbols-$plat.txt"
  local tmp="$cache.tmp"
  local sdk
  sdk="$(xcrun --sdk "$plat" --show-sdk-path)"
  if [ ! -s "$cache" ]; then
    find -L "$sdk" -name '*.tbd' -print0 | xargs -0 perl -0ne '
      while (/symbols:\s*\[(.*?)\]/sg) {
        my $x = $1;
        while ($x =~ /'\''([^'\'']*)'\''|([^,\s\[\]]+)/g) {
          my $s = defined $1 ? $1 : $2;
          next if $s eq "" || $s =~ /^\$/;
          print "$s\n";
        }
      }
      while (/objc-classes:\s*\[(.*?)\]/sg) {
        my $x = $1;
        while ($x =~ /'\''([^'\'']*)'\''|([^,\s\[\]]+)/g) {
          my $s = defined $1 ? $1 : $2;
          print "_OBJC_CLASS_\$_$s\n";
          print "_OBJC_METACLASS_\$_$s\n";
        }
      }
      while (/objc-eh-types:\s*\[(.*?)\]/sg) {
        my $x = $1;
        while ($x =~ /'\''([^'\'']*)'\''|([^,\s\[\]]+)/g) {
          my $s = defined $1 ? $1 : $2;
          print "_OBJC_EHTYPE_\$_$s\n";
        }
      }
      while (/objc-ivars:\s*\[(.*?)\]/sg) {
        my $x = $1;
        while ($x =~ /'\''([^'\'']*)'\''|([^,\s\[\]]+)/g) {
          my $s = defined $1 ? $1 : $2;
          print "_OBJC_IVAR_\$_$s\n";
        }
      }
    ' | sort -u > "$tmp"
    mv "$tmp" "$cache"
  fi
  printf '%s\n' "$cache"
}

validate_unexpected_undefineds() {  # dylib name plat
  local dylib="$1"; local name="$2"; local plat="$3"
  local check_dir="$BUILD/undefined-check/$plat-$name"
  local allow="$check_dir/allow.txt"
  local undef="$check_dir/undefined.txt"
  local bad="$check_dir/bad.txt"
  local sdk_allow
  sdk_allow="$(sdk_symbol_allowlist "$plat")"
  rm -rf "$check_dir"; mkdir -p "$check_dir"

  {
    cat "$sdk_allow"
    printf '%s\n' \
      _entry _main ___dso_handle ___stack_chk_fail ___stack_chk_guard \
      __tlv_bootstrap __Unwind_Resume
    find "$OUT" "$(dirname "$dylib")" -type f -print0 2>/dev/null \
      | xargs -0 nm -gU 2>/dev/null \
      | awk '$NF ~ /^_/ { print $NF }'
  } | sort -u > "$allow"

  nm -u "$dylib" \
    | awk '{ print $NF }' \
    | sort -u \
    | awk '
        /^$/ { next }
        { print }
      ' > "$undef"

  comm -23 "$undef" "$allow" > "$bad"
  if [ -s "$bad" ]; then
    echo "$name: unexpected undefined symbol(s) for $plat:" >&2
    sed 's/^/  /' "$bad" >&2
    echo "$name: link the matching SDK library/framework, or add a microOS shim/non-support source." >&2
    return 1
  fi
}

validate_absent_global_symbols() {  # dylib name symbols...
  local dylib="$1"; local name="$2"; shift 2
  local check_dir="$BUILD/forbidden-symbol-check/$name"
  local symbols="$check_dir/symbols.txt"
  local present="$check_dir/present.txt"
  rm -rf "$check_dir"; mkdir -p "$check_dir"

  printf '%s\n' "$@" | sort -u > "$symbols"
  nm -g "$dylib" 2>/dev/null \
    | awk '$NF ~ /^_/ { print $NF }' \
    | sort -u \
    | grep -Fxf "$symbols" > "$present" || true

  if [ -s "$present" ]; then
    echo "$name: forbidden global symbol(s) present:" >&2
    sed 's/^/  /' "$present" >&2
    return 1
  fi
}

# ---- per-slice build helpers (emit ONE dylib for the current platform) ----

build_swift() {  # out source...
  out="$1"; shift
  local abi_parent
  abi_parent="$(microosabi_framework_parent "$CURRENT_PLATFORM")" || return 1
  xcrun swiftc -emit-library -parse-as-library "${SWIFT_SDK[@]}" "$@" \
    -module-name "$(basename "$out" .dylib | tr -c "[:alnum:]_" "_")" \
    -F "$abi_parent" -Xlinker -framework -Xlinker MicroOSABI \
    -o "$out"
}

build_microosabi() {  # out source...  (the ABI dylib itself — no framework to link)
  out="$1"; shift
  xcrun clang -dynamiclib "${CLANG_SDK[@]}" -I "$INCLUDE" "$@" -o "$out"
}

build_c() {  # out source...  (plain C, no CRT shim; links the host ABI framework)
  out="$1"; shift
  local abi_parent
  abi_parent="$(microosabi_framework_parent "$CURRENT_PLATFORM")" || return 1
  xcrun clang -dynamiclib "${CLANG_SDK[@]}" -I "$INCLUDE" \
    "$@" -F "$abi_parent" -framework MicroOSABI -o "$out"
}

build_c_crt() {  # out source...
  out="$1"; shift; d="$(dirname "$out")"
  local abi_parent
  abi_parent="$(microosabi_framework_parent "$CURRENT_PLATFORM")" || return 1
  xcrun clang -c "${CLANG_SDK[@]}" -I "$INCLUDE" "$CRT/micro_os_crt.c" -o "$d/crt.o"
  xcrun clang -c "${CLANG_SDK[@]}" -I "$INCLUDE" "$CRT/micro_os_libc_shim.c" -o "$d/libc.o"
  xcrun clang -dynamiclib "${CLANG_SDK[@]}" -I "$INCLUDE" \
    -include micro_os_crt.h "$@" "$d/crt.o" "$d/libc.o" \
    -F "$abi_parent" -framework MicroOSABI -o "$out"
}

# wm is a standalone Xcode target. Build it only when explicitly requested, then
# pack the slices into an xcframework. The app scheme does not depend on wm.
build_wm_xcframework() {
  fws=()
  for plat in $PLATFORMS; do
    dir="$BUILD/wm-$plat"
    rm -rf "$dir"; mkdir -p "$dir"
    abi_parent="$(microosabi_framework_parent "$plat")" || return 1
    arch=arm64
    if [ "$plat" = iphonesimulator ]; then arch="$(uname -m)"; fi
    xcrun xcodebuild -project "$ROOT/micro-os.xcodeproj" -target wm \
      -sdk "$plat" -configuration Release \
      CODE_SIGNING_ALLOWED=NO \
      CONFIGURATION_BUILD_DIR="$dir" \
      ARCHS="$arch" \
      FRAMEWORK_SEARCH_PATHS="\"$abi_parent\"" \
      OTHER_LDFLAGS="-framework MicroOSABI" \
      build >/dev/null
    fw="$dir/wm.framework"
    make_framework "$dir/wm.dylib" "$fw" "wm" "$plat"
    fws+=(-framework "$fw")
  done
  rm -rf "$OUT/wm.xcframework"
  xcrun xcodebuild -create-xcframework "${fws[@]}" -output "$OUT/wm.xcframework" >/dev/null
  echo "built wm -> payload/wm.xcframework ($PLATFORMS) [xcodebuild target, framework]"
}

# ---- toybox: vanilla source, never patched (busybox-like shell environment) ----
# Built from upstream toybox into a single entry-exporting dylib. The source is
# downloaded + verified into the git-ignored .build cache, extracted/built in a
# SPACE-FREE scratch dir (toybox's make can't handle the space in "iOS Apps"),
# pruned of commands that don't compile/link for the iOS SDK, and packed into
# payload/toybox.xcframework. System-wide iOS compat shims live in include/
# (e.g. include/sys/disk.h); runtimes/ is reserved for GUI SDK shims.
TOYBOX_VERSION="${TOYBOX_VERSION:-0.8.11}"
TOYBOX_SHA256="${TOYBOX_SHA256:-15aa3f832f4ec1874db761b9950617f99e1e38144c22da39a71311093bfe67dc}"

fetch_toybox() {  # ensures the verified tarball is at $TOYBOX_TARBALL
  TOYBOX_TARBALL="$BUILD/toybox/toybox-$TOYBOX_VERSION.tar.gz"
  mkdir -p "$BUILD/toybox"
  if [ ! -f "$TOYBOX_TARBALL" ]; then
    for url in "https://landley.net/toybox/downloads/toybox-$TOYBOX_VERSION.tar.gz" \
               "http://landley.net/toybox/downloads/toybox-$TOYBOX_VERSION.tar.gz"; do
      echo "  fetching $url"
      curl -fsSL -o "$TOYBOX_TARBALL" "$url" && break
    done
  fi
  [ -f "$TOYBOX_TARBALL" ] || { echo "toybox: download failed" >&2; return 1; }
  got="$(shasum -a 256 "$TOYBOX_TARBALL" | awk '{print $1}')"
  if [ "$got" != "$TOYBOX_SHA256" ]; then
    echo "toybox: sha256 mismatch (got $got, want $TOYBOX_SHA256)" >&2
    rm -f "$TOYBOX_TARBALL"; return 1
  fi
}

build_toybox_slice() {  # out plat   -> writes a single-platform toybox.dylib
  out="$1"; plat="$2"
  sdk="$(xcrun --sdk "$plat" --show-sdk-path)"; cc="$(xcrun -f clang)"
  if [ "$plat" = iphoneos ]; then arch=arm64; minv="-miphoneos-version-min=15.0";
  else arch="$(uname -m)"; minv="-mios-simulator-version-min=15.0"; fi
  tgt="-isysroot $sdk -arch $arch $minv"

  # space-free scratch (repo path has a space; toybox's make would split it).
  # Stage the whole include/ tree so its iOS compat shims (e.g. sys/disk.h)
  # shadow the SDK.
  work="${TOYBOX_WORKDIR:-${TMPDIR:-/tmp}/micro-os-toybox}/$plat"
  rm -rf "$work"; mkdir -p "$work/inc"
  cp -R "$INCLUDE"/. "$work/inc"/

  "$cc" $tgt -c -I "$work/inc" "$CRT/micro_os_crt.c"       -o "$work/crt.o"  || return 1
  "$cc" $tgt -c -I "$work/inc" "$CRT/micro_os_libc_shim.c" -o "$work/libc.o" || return 1

  tar xzf "$TOYBOX_TARBALL" -C "$work" || return 1
  ( cd "$work/toybox-$TOYBOX_VERSION" || exit 1
    make clean >/dev/null 2>&1
    make defconfig >/dev/null 2>&1
    sed -i '' 's/^# CONFIG_SH is not set$/CONFIG_SH=y/' .config          # enable the shell (pending)
    sed -i '' 's/^CONFIG_TOYBOX_ZHELP=y$/# CONFIG_TOYBOX_ZHELP is not set/' .config  # gen broken on macOS
    # A forked child must exec() a fresh process, never run an applet in-process
    # (one address space -> shared globals). Pairs with the CRT fork()-via-spawn.
    sed -i '' 's/^# CONFIG_TOYBOX_NORECURSE is not set$/CONFIG_TOYBOX_NORECURSE=y/' .config
    # Network diagnostics we want available in the default userspace. These are
    # upstream toybox applets; /proc, /dev, and Linux-netlink based tools are
    # deliberately left out instead of faking platform data in the shim.
    # PING/PING6 are NOT listed: toybox ping is Linux-only (millitime-based
    # RTT truncated to unsigned short — fixed 4110ms on Darwin). The shim
    # headers make it compile, so it must be disabled explicitly. Apple's
    # official network_cmds ping is built separately — see build_ping_xcframework.
    en(){ sed -i '' "s/^# CONFIG_$1 is not set\$/CONFIG_$1=y/" .config; }
    for applet in DIFF GZIP HOST MORE TELNET; do en "$applet"; done
    sed -i '' 's/^CONFIG_IFCONFIG=y$/# CONFIG_IFCONFIG is not set/' .config
    sed -i '' 's/^CONFIG_IP=y$/# CONFIG_IP is not set/' .config
    sed -i '' 's/^CONFIG_PING=y$/# CONFIG_PING is not set/' .config
    # linux32 needs personality() — a Linux syscall absent on Apple platforms
    # (macOS too). Disable it explicitly instead of shipping a command that can
    # only fail at runtime.
    sed -i '' 's/^CONFIG_LINUX32=y$/# CONFIG_LINUX32 is not set/' .config
    cflags="$tgt -Dmain=entry -include $work/inc/micro_os_crt.h -I $work/inc -ferror-limit=0"
    # iconv (iconv/iconv_open) and host (res_9_*) live in libiconv/libresolv —
    # present on iOS but not auto-loaded, so link them or those commands fail at
    # dlopen. They are NOT Linux-only (they work on macOS too).
    abi_parent="$(microosabi_framework_parent "$plat")" || exit 1
    ln -sfn "$abi_parent/MicroOSABI.framework" "$work/MicroOSABI.framework"
    ldflags="-dynamiclib -F$work -framework MicroOSABI -liconv -lresolv $work/crt.o $work/libc.o"
    dis(){ sed -i '' "s/^CONFIG_$1=y\$/# CONFIG_$1 is not set/" .config; }
    symf(){ grep -E "^config [A-Z0-9_]+" "$1" 2>/dev/null | awk '{print $2}'; }
    # Disable every command implicated by errors in $1. Sets ch=1 if anything
    # was disabled. Handles both compile errors (source file named) and link
    # errors ("undefined symbol ... referenced from ... in x.o").
    prune_log(){
      ch=""
      # Compile failures. Anchor to the canonical "file:line:col: error:" form at
      # line start so interleaved parallel output can't splice a healthy file's
      # path onto another file's error line (which would prune it spuriously).
      for f in $(grep -oE "^(\./)?toys/[a-z]+/[a-z0-9_]+\.c:[0-9]+:[0-9]+: (fatal error|error):" "$1" \
                 | grep -oE "toys/[a-z]+/[a-z0-9_]+\.c" | sort -u); do
        for s in $(symf "$f"); do dis "$s"; pruned="$pruned $s"; ch=1; done
      done
      # Link failures: "undefined symbol ... referenced from _x_main in x.o". The
      # link step is a single (non-parallel) ld invocation, so this is clean. A
      # .o only appears here if it genuinely references the missing symbol.
      for b in $(grep -oE "in [a-z0-9_]+\.o$" "$1" | awk '{print $2}' | sed 's/\.o$//' | sort -u); do
        f="$(ls toys/*/"$b".c 2>/dev/null | head -1)"; [ -n "$f" ] && for s in $(symf "$f"); do dis "$s"; pruned="$pruned $s"; ch=1; done
      done
    }
    pruned=""
    for r in $(seq 1 60); do
      rm -f generated/zhelp.h
      NOSTRIP=1 make CC="$cc" HOSTCC="xcrun clang" CFLAGS="$cflags" LDFLAGS="$ldflags" >"$work/round.log" 2>&1 && { built=1; break; }
      prune_log "$work/round.log"
      if [ -z "$ch" ]; then
        # toybox builds in parallel; interleaved output can mangle the file name
        # on an error line. Rebuild serially (CPUS=1) for a clean log, then map.
        rm -f generated/zhelp.h
        NOSTRIP=1 CPUS=1 make CC="$cc" HOSTCC="xcrun clang" CFLAGS="$cflags" LDFLAGS="$ldflags" >"$work/round.log" 2>&1 && { built=1; break; }
        prune_log "$work/round.log"
      fi
      if [ -z "$ch" ]; then
        echo "toybox: unmappable build error ($plat):" >&2
        grep -iE "error:|Undefined symbols|referenced from" "$work/round.log" | sort -u | head -15 >&2
        # The above matches only compile/link errors; a make/host-tool/config
        # failure leaves nothing to print. Dump the tail of the build log so the
        # real cause is visible (e.g. on CI, where the log is otherwise hidden).
        echo "----- toybox round.log (tail) -----" >&2
        tail -n 120 "$work/round.log" >&2
        echo "----- end round.log -----" >&2
        exit 1
      fi
    done
    [ -n "${built:-}" ] || { echo "toybox: did not converge in 40 rounds ($plat)" >&2; exit 1; }
    {
      while IFS= read -r line; do
        cfg="${line#USE_}"; [ "$cfg" != "$line" ] || continue
        cfg="${cfg%%(*}"
        grep -q "^#define CFG_$cfg 1$" generated/config.h || continue
        body="${line#*TOY(}"
        name="${body%%,*}"
        case "$name" in ""|-*) continue ;; esac
        printf '%s\n' "$name"
      done < generated/newtoys.h
    } | sort -u > "$out.applets"
    echo "    $plat: pruned$pruned" >&2
    cp -f toybox "$out" ) || return 1   # -f: toybox chmod 555's its output (read-only)
}

# Generate the boot provisioning script (payload/etc/setup-path) from a built
# toybox slice. init sources it via pre-start. It uses the bundled toybox's OWN
# ln (no custom installer); the applet names come from the slice's <name>_main
# symbols and are baked in literally (the kernel's PID-routed I/O can't
# pipe/$()-capture a list at runtime). Every link points at a read-only bundle
# dylib; its missing +x is covered by the kernel's access(). The whole script
# runs INSIDE micro-os, so it provisions identically on simulator and device —
# no host-side commands. Pass a toybox.dylib slice to read applets from.
write_setup_path() {  # slice
  slice="$1"
  [ -f "$slice" ] || { echo "write_setup_path: no slice at $slice" >&2; return 1; }
  mkdir -p "$OUT/etc"
  if [ -s "$slice.applets" ]; then
    applets="$(tr '\n' ' ' < "$slice.applets")"
  else
    applets="$(nm -gU "$slice" 2>/dev/null | grep -oE '_[a-z0-9_]+_main$' | sed 's/^_//; s/_main$//' | sort -u | tr '\n' ' ')"
  fi
  {
    echo '# Generated by build-programs.sh. Sourced by init pre-start.'
    echo '# Provisions userspace entirely from within micro-os (works on device,'
    echo '# no host-side commands): toybox applet links, standalone program'
    echo '# command links, and the bundled app data dir.'
    echo 'T="$FW/toybox.framework/toybox"'
    echo '"$T" mkdir -p "$BIN"'
    echo "for c in $applets"
    echo 'do "$T" ln -sf "$T" "$BIN/$c"'
    echo 'done'
    echo '# Standalone program frameworks (wm, samples, …) -> $BIN/<name>, so the'
    echo '# shell can launch them by name. toybox is the multicall above and'
    echo '# init is PID 1, not a command.'
    echo 'for d in "$FW"/*.framework'
    echo 'do n="${d##*/}"; n="${n%.framework}"'
    echo '   case "$n" in toybox|init|MicroOSABI|libcrypto|libssl|libuv|libisc|libdns|libisccfg|libirs|zlib|libbz2|liblzma) ;; *) "$T" ln -sf "$d/$n" "$BIN/$n";; esac'
    echo 'done'
    echo '# Bundled app data -> the working-dir-relative ./data an app expects'
    echo '# (an app that reads ./data from its CWD finds it at $HOME/data).'
    echo '[ -e "$BUNDLE/data" ] && "$T" ln -sf "$BUNDLE/data" "$HOME/data"'
    echo 'true'
  } > "$OUT/etc/setup-path"
  echo "wrote setup-path ($(echo $applets | wc -w | tr -d ' ') applets + program/data links) -> payload/etc/setup-path"
}

build_toybox_xcframework() {
  fetch_toybox || return 1
  fws=()
  for plat in $PLATFORMS; do
    mkdir -p "$BUILD/$plat"
    slice="$BUILD/$plat/toybox.dylib"
    echo "  building toybox slice: $plat"
    build_toybox_slice "$slice" "$plat" || return 1
    fw="$BUILD/$plat/toybox.framework"
    make_framework "$slice" "$fw" "toybox" "$plat"
    fws+=(-framework "$fw")
  done
  rm -rf "$OUT/toybox.xcframework"
  xcrun xcodebuild -create-xcframework "${fws[@]}" -output "$OUT/toybox.xcframework" >/dev/null
  echo "built toybox -> payload/toybox.xcframework ($PLATFORMS) [vanilla $TOYBOX_VERSION, auto-pruned, framework]"

  write_setup_path "$BUILD/${PLATFORMS%% *}/toybox.dylib"
}

# ---- curl: official source + official OpenSSL, built without patching either ----
# curl no longer ships an Apple-native TLS backend by itself; HTTPS needs a TLS
# backend. Build upstream OpenSSL statically, then build upstream curl against it
# with Apple SecTrust enabled so certificate verification uses the platform trust
# store. The upstream source trees are never patched: microOS integration is only
# via compiler/linker flags and the CRT/libc shim objects linked into the final
# dylib.
CURL_VERSION="${CURL_VERSION:-8.20.0}"
CURL_SHA256="${CURL_SHA256:-63fe2dc148ba0ceae89922ef838f7e5c946272c2e78b7c59fab4b79d3ce2b896}"
OPENSSL_VERSION="${OPENSSL_VERSION:-3.0.21}"
OPENSSL_SHA256="${OPENSSL_SHA256:-617e29af8e421f46649484a4937e48c685e47f46488167c982f88bc4ec1d522f}"
BIND_OPENSSL_VERSION="${BIND_OPENSSL_VERSION:-1.1.1w}"
BIND_OPENSSL_SHA256="${BIND_OPENSSL_SHA256:-cf3098950cb4d853ad95c0841f1f9c6d3dc102dccfcacd521d93925208b76ac8}"
BIND_OPENSSL_RELEASE_TAG="${BIND_OPENSSL_RELEASE_TAG:-OpenSSL_1_1_1w}"
BIND_OPENSSL_DYLIB_SUFFIX="${BIND_OPENSSL_DYLIB_SUFFIX:-1.1}"
LIBUV_VERSION="${LIBUV_VERSION:-1.52.1}"
LIBUV_SHA256="${LIBUV_SHA256:-478baf2599bfbc882c355288c9cb6f92e0e7dda435fa04031fa5b607cf3f414c}"
BIND_VERSION="${BIND_VERSION:-9.18.50}"
BIND_SHA256="${BIND_SHA256:-a24f93be94712a8c11752294410f2f8a2510ec7fdc931d207fc61cdf30e54f4d}"
BIND_LIBCRYPTO_INSTALL_NAME="@loader_path/../libcrypto.framework/libcrypto"
BIND_LIBSSL_INSTALL_NAME="@loader_path/../libssl.framework/libssl"
BIND_LIBUV_INSTALL_NAME="@loader_path/../libuv.framework/libuv"
BIND_LIBISC_INSTALL_NAME="@loader_path/../libisc.framework/libisc"
BIND_LIBDNS_INSTALL_NAME="@loader_path/../libdns.framework/libdns"
BIND_LIBISCCFG_INSTALL_NAME="@loader_path/../libisccfg.framework/libisccfg"
BIND_LIBIRS_INSTALL_NAME="@loader_path/../libirs.framework/libirs"

fetch_verified_tarball() {  # name version url sha out
  local name="$1"; local version="$2"; local url="$3"; local want="$4"; local out="$5"
  mkdir -p "$(dirname "$out")"
  if [ ! -f "$out" ]; then
    echo "  fetching $url"
    curl -fsSL -o "$out" "$url" || return 1
  fi
  local got
  got="$(shasum -a 256 "$out" | awk '{print $1}')"
  if [ "$got" != "$want" ]; then
    echo "$name: sha256 mismatch for $version (got $got, want $want)" >&2
    rm -f "$out"; return 1
  fi
}

fetch_verified_file() {  # name version url sha out
  local name="$1"; local version="$2"; local url="$3"; local want="$4"; local out="$5"
  mkdir -p "$(dirname "$out")"
  if [ ! -f "$out" ]; then
    echo "  fetching $url"
    curl -fsSL -o "$out" "$url" || return 1
  fi
  local got
  got="$(shasum -a 256 "$out" | awk '{print $1}')"
  if [ "$got" != "$want" ]; then
    echo "$name: sha256 mismatch for $version (got $got, want $want)" >&2
    rm -f "$out"; return 1
  fi
}

fetch_curl_sources() {
  CURL_TARBALL="$BUILD/curl/curl-$CURL_VERSION.tar.xz"
  OPENSSL_TARBALL="$BUILD/curl/openssl-$OPENSSL_VERSION.tar.gz"
  fetch_verified_tarball curl "$CURL_VERSION" \
    "https://curl.se/download/curl-$CURL_VERSION.tar.xz" \
    "$CURL_SHA256" "$CURL_TARBALL"
  fetch_verified_tarball openssl "$OPENSSL_VERSION" \
    "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" \
    "$OPENSSL_SHA256" "$OPENSSL_TARBALL"
}

fetch_libuv_sources() {
  LIBUV_TARBALL="$BUILD/libuv/libuv-v$LIBUV_VERSION.tar.gz"
  fetch_verified_tarball libuv "$LIBUV_VERSION" \
    "https://github.com/libuv/libuv/archive/refs/tags/v$LIBUV_VERSION.tar.gz" \
    "$LIBUV_SHA256" "$LIBUV_TARBALL"
}

fetch_bind_openssl_sources() {
  BIND_OPENSSL_TARBALL="$BUILD/bind/openssl-$BIND_OPENSSL_VERSION.tar.gz"
  fetch_verified_tarball openssl "$BIND_OPENSSL_VERSION" \
    "https://github.com/openssl/openssl/releases/download/$BIND_OPENSSL_RELEASE_TAG/openssl-$BIND_OPENSSL_VERSION.tar.gz" \
    "$BIND_OPENSSL_SHA256" "$BIND_OPENSSL_TARBALL"
}

fetch_bind_sources() {
  BIND_TARBALL="$BUILD/bind/bind-$BIND_VERSION.tar.xz"
  fetch_verified_tarball bind "$BIND_VERSION" \
    "https://downloads.isc.org/isc/bind9/$BIND_VERSION/bind-$BIND_VERSION.tar.xz" \
    "$BIND_SHA256" "$BIND_TARBALL"
}

curl_platform_vars() {  # plat -> sets sdk arch minv host openssl_target target_flags
  case "$1" in
    iphoneos)
      sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
      arch=arm64
      minv="-miphoneos-version-min=15.0"
      host="aarch64-apple-darwin"
      openssl_target="ios64-xcrun"
      openssl_flags="$minv"
      ;;
    iphonesimulator)
      sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
      arch="$(uname -m)"
      minv="-mios-simulator-version-min=15.0"
      case "$arch" in
        arm64)  host="aarch64-apple-darwin"; openssl_target="iossimulator-xcrun" ;;
        x86_64) host="x86_64-apple-darwin"; openssl_target="iossimulator-xcrun" ;;
        *) echo "curl: unsupported simulator arch: $arch" >&2; return 1 ;;
      esac
      openssl_flags="$minv"
      ;;
    *) echo "unknown platform: $1 (use iphoneos | iphonesimulator)" >&2; return 1 ;;
  esac
  target_flags="-isysroot $sdk -arch $arch $minv"
}

build_openssl_for_curl() {  # plat prefix
  local plat="$1"; local prefix="$2"
  curl_platform_vars "$plat"
  if [ -f "$prefix/lib/libssl.a" ] && [ -f "$prefix/lib/libcrypto.a" ]; then
    return 0
  fi

  local ossl_src="$BUILD/curl/openssl-$plat-src"
  rm -rf "$ossl_src" "$prefix"
  mkdir -p "$ossl_src" "$prefix"
  tar -xf "$OPENSSL_TARBALL" -C "$ossl_src" --strip-components 1
  (
    cd "$ossl_src"
    ./Configure "$openssl_target" no-shared no-tests no-ui-console no-asm no-module \
      --prefix="$prefix" --openssldir="$prefix/ssl" $openssl_flags
    make -j"${MAKE_JOBS:-2}" build_libs
    mkdir -p "$prefix/include" "$prefix/lib"
    cp -R include/openssl "$prefix/include/"
    cp -f libssl.a libcrypto.a "$prefix/lib/"
  ) || return 1
}

build_openssl_dynamic() {  # plat prefix
  local plat="$1"; local prefix="$2"
  curl_platform_vars "$plat"
  local ssl_dylib="$prefix/lib/libssl.$BIND_OPENSSL_DYLIB_SUFFIX.dylib"
  local crypto_dylib="$prefix/lib/libcrypto.$BIND_OPENSSL_DYLIB_SUFFIX.dylib"
  if [ -f "$ssl_dylib" ] && [ -f "$crypto_dylib" ]; then
    xcrun install_name_tool -id "$BIND_LIBCRYPTO_INSTALL_NAME" "$crypto_dylib" 2>/dev/null || true
    xcrun install_name_tool -id "$BIND_LIBSSL_INSTALL_NAME" "$ssl_dylib" 2>/dev/null || true
    xcrun install_name_tool -change "$crypto_dylib" \
      "$BIND_LIBCRYPTO_INSTALL_NAME" "$ssl_dylib" 2>/dev/null || true
    xcrun install_name_tool -change "@rpath/libcrypto.framework/libcrypto" \
      "$BIND_LIBCRYPTO_INSTALL_NAME" "$ssl_dylib" 2>/dev/null || true
    return 0
  fi

  local ossl_src="$prefix-src"
  rm -rf "$ossl_src" "$prefix"
  mkdir -p "$ossl_src" "$prefix"
  tar -xf "$BIND_OPENSSL_TARBALL" -C "$ossl_src" --strip-components 1
  (
    cd "$ossl_src"
    ./Configure "$openssl_target" shared no-tests no-ui-console no-asm \
      --prefix="$prefix" --openssldir="$prefix/ssl" $openssl_flags || exit 1
    make -j"${MAKE_JOBS:-2}" build_libs || exit 1
    mkdir -p "$prefix/include" "$prefix/lib"
    cp -R include/openssl "$prefix/include/"
    cp -f libssl*.dylib libcrypto*.dylib "$prefix/lib/"
    xcrun install_name_tool -id "$BIND_LIBCRYPTO_INSTALL_NAME" "$crypto_dylib"
    xcrun install_name_tool -id "$BIND_LIBSSL_INSTALL_NAME" "$ssl_dylib"
    xcrun install_name_tool -change "$crypto_dylib" \
      "$BIND_LIBCRYPTO_INSTALL_NAME" "$ssl_dylib"
  ) || return 1
}

build_libuv_dynamic() {  # plat prefix
  local plat="$1"; local prefix="$2"
  fetch_libuv_sources
  curl_platform_vars "$plat"
  if [ -f "$prefix/lib/libuv.dylib" ]; then
    xcrun install_name_tool -id "$BIND_LIBUV_INSTALL_NAME" "$prefix/lib/libuv.dylib" 2>/dev/null || true
    return 0
  fi

  local src="$prefix-src"
  local objdir="$prefix-obj"
  rm -rf "$src" "$objdir" "$prefix"
  mkdir -p "$src" "$objdir" "$prefix/include" "$prefix/lib"
  tar -xf "$LIBUV_TARBALL" -C "$src" --strip-components 1
  cp -R "$src/include"/. "$prefix/include"/

  local cc="$(xcrun -f clang)"
  local uv_flags="$target_flags -fPIC -I$prefix/include -I$src/src -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE -D_DARWIN_UNLIMITED_SELECT=1 -D_DARWIN_USE_64_BIT_INODE=1"
  local sources=(
    src/fs-poll.c src/idna.c src/inet.c src/random.c src/strscpy.c
    src/strtok.c src/thread-common.c src/threadpool.c src/timer.c
    src/uv-common.c src/uv-data-getter-setters.c src/version.c
    src/unix/async.c src/unix/core.c src/unix/dl.c src/unix/fs.c
    src/unix/getaddrinfo.c src/unix/getnameinfo.c src/unix/loop-watcher.c
    src/unix/loop.c src/unix/pipe.c src/unix/poll.c src/unix/process.c
    src/unix/random-devurandom.c src/unix/signal.c src/unix/stream.c
    src/unix/tcp.c src/unix/thread.c src/unix/tty.c src/unix/udp.c
    src/unix/proctitle.c src/unix/bsd-ifaddrs.c src/unix/kqueue.c
    src/unix/random-getentropy.c src/unix/darwin-proctitle.c
    src/unix/darwin.c src/unix/fsevents.c
  )
  local objects=()
  local file obj
  for file in "${sources[@]}"; do
    obj="$objdir/${file//\//_}.o"
    "$cc" -c $uv_flags "$src/$file" -o "$obj"
    objects+=("$obj")
  done
  "$cc" -dynamiclib $target_flags -install_name "$BIND_LIBUV_INSTALL_NAME" \
    "${objects[@]}" -lm -o "$prefix/lib/libuv.dylib"
}

build_curl_slice() {  # out plat
  local out="$1"; local plat="$2"
  fetch_curl_sources
  curl_platform_vars "$plat"

  local cc="$(xcrun -f clang)"
  local ar="$(xcrun -f ar)"
  local ranlib="$(xcrun -f ranlib)"
  local d="$(dirname "$out")"
  local curl_src="$BUILD/curl/curl-$plat-src"
  local ossl="$BUILD/curl/openssl-$plat"
  local abi_parent
  abi_parent="$(microosabi_framework_parent "$plat")" || return 1

  build_openssl_for_curl "$plat" "$ossl"

  rm -rf "$curl_src"; mkdir -p "$curl_src"
  tar -xf "$CURL_TARBALL" -C "$curl_src" --strip-components 1

  "$cc" $target_flags -c -I "$INCLUDE" "$CRT/micro_os_crt.c" -o "$d/curl-crt.o"
  "$cc" $target_flags -c -I "$INCLUDE" "$CRT/micro_os_libc_shim.c" -o "$d/curl-libc.o"

  (
    cd "$curl_src"
    env \
      CC="$cc" CPP="$cc $target_flags -E" AR="$ar" RANLIB="$ranlib" PKG_CONFIG=/usr/bin/false \
      CPPFLAGS="-I$INCLUDE -I$ossl/include -include micro_os_crt.h" \
      CFLAGS="$target_flags -fPIC" \
      LDFLAGS="$target_flags -L$ossl/lib -framework Security -framework CoreFoundation" \
      ./configure \
        --host="$host" \
        --disable-shared \
        --enable-static \
        --disable-docs \
        --disable-manual \
        --disable-ldap \
        --disable-ldaps \
        --disable-rtsp \
        --disable-dict \
        --disable-telnet \
        --disable-tftp \
        --disable-pop3 \
        --disable-imap \
        --disable-smb \
        --disable-smtp \
        --disable-gopher \
        --disable-mqtt \
        --disable-ipfs \
        --disable-websockets \
        --disable-doh \
        --without-zlib \
        --without-brotli \
        --without-zstd \
        --without-libpsl \
        --without-nghttp2 \
        --without-nghttp3 \
        --with-openssl="$ossl" \
        --with-apple-sectrust \
        --enable-ca-native
    make -j"${MAKE_JOBS:-2}" -C lib libcurl.la
    make -j"${MAKE_JOBS:-2}" -C src curl \
      LDFLAGS="$target_flags -dynamiclib -Wl,-alias,_main,_entry $d/curl-crt.o $d/curl-libc.o -F$abi_parent -framework MicroOSABI -L$ossl/lib" \
      LIBS="-framework Security -framework CoreFoundation"
    cp -f src/curl "$out"
  ) || return 1
}

build_curl_xcframework() {
  fetch_curl_sources || return 1
  fws=()
  for plat in $PLATFORMS; do
    mkdir -p "$BUILD/$plat"
    slice="$BUILD/$plat/curl.dylib"
    echo "  building curl slice: $plat"
    build_curl_slice "$slice" "$plat" || return 1
    fw="$BUILD/$plat/curl.framework"
    make_framework "$slice" "$fw" "curl" "$plat"
    fws+=(-framework "$fw")
  done
  rm -rf "$OUT/curl.xcframework"
  xcrun xcodebuild -create-xcframework "${fws[@]}" -output "$OUT/curl.xcframework" >/dev/null
  echo "built curl -> payload/curl.xcframework ($PLATFORMS) [official curl $CURL_VERSION + OpenSSL $OPENSSL_VERSION, framework]"
}

# ---- BIND dig/nslookup: official ISC BIND + dynamic libuv/OpenSSL deps ----
# BIND 9.20 adds a liburcu dependency even for the tool build; keep the first
# pass lean by using the official 9.18 ESV tarball. Source trees are not patched:
# generated headers come from BIND's own gen tool, libuv is built from its
# upstream source list, and integration is via configure/link/install-name flags.
write_fake_pkg_config() {  # out
  local out="$1"
  cat > "$out" <<'EOF'
#!/bin/sh
case "$1" in
  --atleast-pkgconfig-version) exit 0 ;;
  --exists) exit 0 ;;
  --modversion) case "$2" in libuv) echo "$LIBUV_VERSION" ;; *) echo 1.0.0 ;; esac; exit 0 ;;
  --cflags|--libs|--short-errors|--print-errors) exit 0 ;;
esac
exit 0
EOF
  chmod +x "$out"
}

fix_bind_install_names() {  # bind_src openssl_prefix
  local src="$1"
  local ossl="$2"
  xcrun install_name_tool -id "$BIND_LIBISC_INSTALL_NAME" "$src/lib/isc/.libs/libisc-$BIND_VERSION.dylib"
  xcrun install_name_tool -id "$BIND_LIBDNS_INSTALL_NAME" "$src/lib/dns/.libs/libdns-$BIND_VERSION.dylib"
  xcrun install_name_tool -id "$BIND_LIBISCCFG_INSTALL_NAME" "$src/lib/isccfg/.libs/libisccfg-$BIND_VERSION.dylib"
  xcrun install_name_tool -id "$BIND_LIBIRS_INSTALL_NAME" "$src/lib/irs/.libs/libirs-$BIND_VERSION.dylib"
  local dylib
  for dylib in "$src/lib/isc/.libs/libisc-$BIND_VERSION.dylib" \
               "$src/lib/dns/.libs/libdns-$BIND_VERSION.dylib" \
               "$src/lib/isccfg/.libs/libisccfg-$BIND_VERSION.dylib" \
               "$src/lib/irs/.libs/libirs-$BIND_VERSION.dylib"; do
    xcrun install_name_tool -change "/usr/local/lib/libisc-$BIND_VERSION.dylib" "$BIND_LIBISC_INSTALL_NAME" "$dylib" 2>/dev/null || true
    xcrun install_name_tool -change "/usr/local/lib/libdns-$BIND_VERSION.dylib" "$BIND_LIBDNS_INSTALL_NAME" "$dylib" 2>/dev/null || true
    xcrun install_name_tool -change "/usr/local/lib/libisccfg-$BIND_VERSION.dylib" "$BIND_LIBISCCFG_INSTALL_NAME" "$dylib" 2>/dev/null || true
    xcrun install_name_tool -change "$ossl/lib/libssl.$BIND_OPENSSL_DYLIB_SUFFIX.dylib" "$BIND_LIBSSL_INSTALL_NAME" "$dylib" 2>/dev/null || true
    xcrun install_name_tool -change "$ossl/lib/libcrypto.$BIND_OPENSSL_DYLIB_SUFFIX.dylib" "$BIND_LIBCRYPTO_INSTALL_NAME" "$dylib" 2>/dev/null || true
  done
}

microosabi_framework_parent() {  # plat
  local plat="$1"
  framework_parent MicroOSABI "$plat"
}

framework_parent() {  # name plat
  local name="$1"
  local plat="$2"
  local xcf="$OUT/$name.xcframework"
  local fw=""
  [ -d "$xcf" ] || { echo "$name.xcframework not found; build $name first" >&2; return 1; }
  case "$plat" in
    iphoneos)
      fw="$(find "$xcf" -path "*/$name.framework" -type d | grep -v simulator | head -n 1 || true)"
      ;;
    iphonesimulator)
      fw="$(find "$xcf" -path "*/$name.framework" -type d | grep simulator | head -n 1 || true)"
      ;;
  esac
  [ -n "$fw" ] || { echo "$name.xcframework slice for $plat not found; build $name first" >&2; return 1; }
  dirname "$fw"
}

relink_bind_dns_libs_twolevel() {  # bind_src products uv_prefix openssl_prefix shim_obj abi_framework_parent target_flags...
  local src="$1"; local products="$2"; local uv="$3"; local ossl="$4"
  local shim_obj="$5"
  local abi_parent="$6"
  shift 6
  local target_flags="$*"
  local ssl_dep="$ossl/lib/libssl.$BIND_OPENSSL_DYLIB_SUFFIX.dylib"
  local crypto_dep="$ossl/lib/libcrypto.$BIND_OPENSSL_DYLIB_SUFFIX.dylib"

  find "$src/lib/isc" -name '*.o' -print > "$products/libisc-objs.rsp"
  "$cc" -dynamiclib $target_flags \
    -install_name "$BIND_LIBISC_INSTALL_NAME" \
    -o "$products/libisc.dylib" @"$products/libisc-objs.rsp" \
    "$shim_obj" \
    -F"$abi_parent" -framework MicroOSABI \
    -L"$uv/lib" -L"$ossl/lib" -luv -lssl -lcrypto

  find "$src/lib/dns" -name '*.o' -print > "$products/libdns-objs.rsp"
  "$cc" -dynamiclib $target_flags \
    -install_name "$BIND_LIBDNS_INSTALL_NAME" \
    -o "$products/libdns.dylib" @"$products/libdns-objs.rsp" \
    -L"$products" -L"$uv/lib" -L"$ossl/lib" -lisc -luv -lssl -lcrypto

  find "$src/lib/isccfg" -name '*.o' -print > "$products/libisccfg-objs.rsp"
  "$cc" -dynamiclib $target_flags \
    -install_name "$BIND_LIBISCCFG_INSTALL_NAME" \
    -o "$products/libisccfg.dylib" @"$products/libisccfg-objs.rsp" \
    -L"$products" -ldns -lisc

  find "$src/lib/irs" -name '*.o' -print > "$products/libirs-objs.rsp"
  "$cc" -dynamiclib $target_flags \
    -install_name "$BIND_LIBIRS_INSTALL_NAME" \
    -o "$products/libirs.dylib" @"$products/libirs-objs.rsp" \
    -L"$products" -lisc -ldns -lisccfg

  local dylib
  for dylib in "$products/libisc.dylib" "$products/libdns.dylib" \
               "$products/libisccfg.dylib" "$products/libirs.dylib"; do
    xcrun install_name_tool -change "$ssl_dep" "$BIND_LIBSSL_INSTALL_NAME" "$dylib" 2>/dev/null || true
    xcrun install_name_tool -change "$crypto_dep" "$BIND_LIBCRYPTO_INSTALL_NAME" "$dylib" 2>/dev/null || true
    xcrun install_name_tool -change "$uv/lib/libuv.dylib" "$BIND_LIBUV_INSTALL_NAME" "$dylib" 2>/dev/null || true
    xcrun install_name_tool -change "$products/libisc.dylib" "$BIND_LIBISC_INSTALL_NAME" "$dylib" 2>/dev/null || true
    xcrun install_name_tool -change "$products/libdns.dylib" "$BIND_LIBDNS_INSTALL_NAME" "$dylib" 2>/dev/null || true
    xcrun install_name_tool -change "$products/libisccfg.dylib" "$BIND_LIBISCCFG_INSTALL_NAME" "$dylib" 2>/dev/null || true
  done
}

build_bind_dns_tools_slice_set() {  # plat product_dir
  local plat="$1"; local products="$2"
  fetch_bind_openssl_sources
  fetch_bind_sources
  fetch_libuv_sources
  curl_platform_vars "$plat"

  local cc="$(xcrun -f clang)"
  local ar="$(xcrun -f ar)"
  local ranlib="$(xcrun -f ranlib)"
  local host_triplet="$host"

  # Build everything under a space-free directory — autoconf/make break on
  # paths containing spaces (e.g. "iOS Apps").
  local bind_work="${TMPDIR:-/tmp}/micro-os-bind/$plat"
  rm -rf "$bind_work"
  mkdir -p "$bind_work"

  local ossl="$bind_work/ossl"
  local uv="$bind_work/uv"
  local fake_pkg="$bind_work/pkg-config-fake"
  local bind_src="$bind_work/src"
  ln -sfn "$INCLUDE" "$bind_work/include"

  build_openssl_dynamic "$plat" "$ossl"
  build_libuv_dynamic "$plat" "$uv"
  write_fake_pkg_config "$fake_pkg"

  rm -rf "$bind_src" "$products"
  mkdir -p "$bind_src" "$products"
  tar -xf "$BIND_TARBALL" -C "$bind_src" --strip-components 1

  (
    cd "$bind_src"
    env \
      LIBUV_VERSION="$LIBUV_VERSION" \
      CC="$cc" AR="$ar" RANLIB="$ranlib" PKG_CONFIG="$fake_pkg" \
      LIBUV_CFLAGS="-I$uv/include" LIBUV_LIBS="-L$uv/lib -luv -lpthread -lm" \
      OPENSSL_CFLAGS="-I$ossl/include" OPENSSL_LIBS="-L$ossl/lib -lssl -lcrypto" \
      CFLAGS="$target_flags -fPIC" \
      CPPFLAGS="-I$bind_work/include" \
      LDFLAGS="$target_flags -L$uv/lib -L$ossl/lib" \
      ./configure --host="$host_triplet" --disable-doh --disable-geoip \
        --without-lmdb --without-libxml2 --without-json-c --without-zlib \
        --without-readline --without-libidn2 --without-cmocka \
        --without-jemalloc --without-gssapi
    # BIND's generated Darwin libtool still defaults to unresolved lookup for
    # intermediate dylibs. The final shipped dylibs are linked by this script,
    # but keep the build itself under the same rule.
    perl -0pi -e 's/^allow_undefined_flag=.*$/allow_undefined_flag=""/m; s/\s-flat\x5fnamespace//g; s/\$wl\x2dundefined\s+\$\{wl\}dynamic\x5flookup\s+\$wl-no_fixup_chains//g' libtool
    make -j"${MAKE_JOBS:-2}" -C lib/isc all
    make -j"${MAKE_JOBS:-2}" -C lib/dns all
    make -j"${MAKE_JOBS:-2}" -C lib/isccfg all
    make -j"${MAKE_JOBS:-2}" -C lib/irs all
    make -j"${MAKE_JOBS:-2}" -C bin/dig libdighost.la
  ) || return 1

  fix_bind_install_names "$bind_src" "$ossl"

  cp -f "$ossl/lib/libcrypto.$BIND_OPENSSL_DYLIB_SUFFIX.dylib" "$products/libcrypto.dylib"
  cp -f "$ossl/lib/libssl.$BIND_OPENSSL_DYLIB_SUFFIX.dylib" "$products/libssl.dylib"
  cp -f "$uv/lib/libuv.dylib" "$products/libuv.dylib"

  "$cc" -c $target_flags -I "$INCLUDE" "$CRT/micro_os_crt.c" -o "$products/bind-crt.o"
  "$cc" -c $target_flags -I "$INCLUDE" "$CRT/micro_os_libc_shim.c" -o "$products/bind-libc.o"
  local abi_parent
  abi_parent="$(microosabi_framework_parent "$plat")" || return 1
  relink_bind_dns_libs_twolevel "$bind_src" "$products" "$uv" "$ossl" "$products/bind-libc.o" "$abi_parent" $target_flags

  local bind_cpp="-D_FORTIFY_SOURCE=2 -include $bind_src/config.h -I$bind_src/bin/dig -I$bind_src/bin/dig/include -I$bind_src/include -I$bind_src/lib/isc/include -I$bind_src/lib/dns/include -I$bind_src/lib/irs/include -I$bind_src/lib/isccfg/include -I$bind_src/lib/bind9/include"
  "$cc" -c $target_flags -fPIC $bind_cpp "$bind_src/lib/bind9/getaddresses.c" -o "$products/getaddresses.o"

  local prog obj
  for prog in dig nslookup; do
    if [ "$prog" = dig ]; then
      obj="$products/dig.o"
      "$cc" -c $target_flags -fPIC $bind_cpp "$bind_src/bin/dig/dig.c" -o "$obj"
    else
      obj="$products/nslookup.o"
      "$cc" -c $target_flags -fPIC $bind_cpp "$bind_src/bin/dig/nslookup.c" -o "$obj"
    fi
    "$cc" -dynamiclib $target_flags -Wl,-alias,_main,_entry \
      "$products/bind-crt.o" "$products/bind-libc.o" "$obj" \
      "$bind_src/bin/dig/.libs/dighost.o" "$products/getaddresses.o" \
      "$products/libirs.dylib" "$products/libisccfg.dylib" \
      "$products/libdns.dylib" "$products/libisc.dylib" \
      "$products/libuv.dylib" "$products/libssl.dylib" "$products/libcrypto.dylib" \
      -F"$abi_parent" -framework MicroOSABI \
      -o "$products/$prog.dylib"
    xcrun install_name_tool -id "@rpath/$prog.framework/$prog" "$products/$prog.dylib" 2>/dev/null || true
    xcrun install_name_tool -change "$products/libirs.dylib" "$BIND_LIBIRS_INSTALL_NAME" "$products/$prog.dylib" 2>/dev/null || true
    xcrun install_name_tool -change "$products/libisccfg.dylib" "$BIND_LIBISCCFG_INSTALL_NAME" "$products/$prog.dylib" 2>/dev/null || true
    xcrun install_name_tool -change "$products/libdns.dylib" "$BIND_LIBDNS_INSTALL_NAME" "$products/$prog.dylib" 2>/dev/null || true
    xcrun install_name_tool -change "$products/libisc.dylib" "$BIND_LIBISC_INSTALL_NAME" "$products/$prog.dylib" 2>/dev/null || true
    xcrun install_name_tool -change "$products/libuv.dylib" "$BIND_LIBUV_INSTALL_NAME" "$products/$prog.dylib" 2>/dev/null || true
    xcrun install_name_tool -change "$products/libssl.dylib" "$BIND_LIBSSL_INSTALL_NAME" "$products/$prog.dylib" 2>/dev/null || true
    xcrun install_name_tool -change "$products/libcrypto.dylib" "$BIND_LIBCRYPTO_INSTALL_NAME" "$products/$prog.dylib" 2>/dev/null || true
  done
}

build_bind_dns_tools_xcframework() {
  local names=(libcrypto libssl libuv libisc libdns libisccfg libirs dig nslookup)
  local name plat products fw
  for plat in $PLATFORMS; do
    products="$BUILD/bind/products-$plat"
    echo "  building BIND dns tools slice set: $plat"
    build_bind_dns_tools_slice_set "$plat" "$products" || return 1
    for name in "${names[@]}"; do
      fw="$BUILD/bind/$plat/$name.framework"
      make_framework "$products/$name.dylib" "$fw" "$name" "$plat"
    done
  done
  for name in "${names[@]}"; do
    local fws=()
    for plat in $PLATFORMS; do
      fws+=(-framework "$BUILD/bind/$plat/$name.framework")
    done
    rm -rf "$OUT/$name.xcframework"
    xcrun xcodebuild -create-xcframework "${fws[@]}" -output "$OUT/$name.xcframework" >/dev/null
    echo "built $name -> payload/$name.xcframework ($PLATFORMS) [official BIND $BIND_VERSION dynamic deps, framework]"
  done
}

# ---- ifconfig: Apple network_cmds (BSD/Darwin), built without source patches ----
# toybox ifconfig is Linux-oriented and starts from /proc/net/dev. Use Apple's
# official network_cmds ifconfig instead: it enumerates interfaces via Darwin
# getifaddrs/ioctl/sysctl paths. The source tree is unmodified; microOS only
# supplies the CRT/libc shim and one userland nd6 compatibility header.
NETWORK_CMDS_VERSION="${NETWORK_CMDS_VERSION:-329.2.2}"
NETWORK_CMDS_SHA256="${NETWORK_CMDS_SHA256:-3bf14d573c42888910a73cc3f914d2e023defcd7d13b1e525a55b2443a5a5cfa}"

fetch_network_cmds_sources() {
  NETWORK_CMDS_TARBALL="$BUILD/network_cmds/network_cmds-$NETWORK_CMDS_VERSION.tar.gz"
  fetch_verified_tarball network_cmds "$NETWORK_CMDS_VERSION" \
    "https://github.com/apple-oss-distributions/network_cmds/archive/refs/tags/network_cmds-$NETWORK_CMDS_VERSION.tar.gz" \
    "$NETWORK_CMDS_SHA256" "$NETWORK_CMDS_TARBALL"
}

build_ifconfig_slice() {  # out plat
  local out="$1"; local plat="$2"
  fetch_network_cmds_sources

  local sdk arch minv macsdk kern cc d src
  sdk="$(xcrun --sdk "$plat" --show-sdk-path)"
  cc="$(xcrun -f clang)"
  if [ "$plat" = iphoneos ]; then
    arch=arm64
    minv="-miphoneos-version-min=15.0"
  else
    arch="$(uname -m)"
    minv="-mios-simulator-version-min=15.0"
  fi
  macsdk="$(xcrun --sdk macosx --show-sdk-path)"
  kern="$macsdk/System/Library/Frameworks/Kernel.framework/Versions/A/Headers"
  d="$(dirname "$out")"
  src="$BUILD/network_cmds/network_cmds-$plat-src"

  rm -rf "$src"; mkdir -p "$src"
  tar -xf "$NETWORK_CMDS_TARBALL" -C "$src" --strip-components 1

  "$cc" -isysroot "$sdk" -arch "$arch" $minv -I "$INCLUDE" \
    -c "$CRT/micro_os_crt.c" -o "$d/ifconfig-crt.o"
  "$cc" -isysroot "$sdk" -arch "$arch" $minv -I "$INCLUDE" \
    -c "$CRT/micro_os_libc_shim.c" -o "$d/ifconfig-libc.o"

  local abi_parent
  abi_parent="$(microosabi_framework_parent "$plat")" || return 1
  local base_flags=(-isysroot "$sdk" -arch "$arch" $minv
    -I "$INCLUDE" -I "$src/ifconfig.tproj"
    -idirafter "$kern" -idirafter "$macsdk/usr/include")
  local prog_flags=("${base_flags[@]}" -Dmain=entry -include micro_os_crt.h)
  local objects=("$d/ifconfig-crt.o" "$d/ifconfig-libc.o")
  local file obj
  for file in ifconfig.c af_inet.c af_inet6.c af_link.c ifclone.c ifmedia.c; do
    obj="$d/ifconfig-${file%.c}.o"
    "$cc" -c "${prog_flags[@]}" "$src/ifconfig.tproj/$file" -o "$obj"
    objects+=("$obj")
  done

  "$cc" -dynamiclib -isysroot "$sdk" -arch "$arch" $minv \
    "${objects[@]}" -F "$abi_parent" -framework MicroOSABI -o "$out"
}

build_ifconfig_xcframework() {
  fetch_network_cmds_sources || return 1
  fws=()
  for plat in $PLATFORMS; do
    mkdir -p "$BUILD/$plat"
    slice="$BUILD/$plat/ifconfig.dylib"
    echo "  building ifconfig slice: $plat"
    build_ifconfig_slice "$slice" "$plat" || return 1
    fw="$BUILD/$plat/ifconfig.framework"
    make_framework "$slice" "$fw" "ifconfig" "$plat"
    fws+=(-framework "$fw")
  done
  rm -rf "$OUT/ifconfig.xcframework"
  xcrun xcodebuild -create-xcframework "${fws[@]}" -output "$OUT/ifconfig.xcframework" >/dev/null
  echo "built ifconfig -> payload/ifconfig.xcframework ($PLATFORMS) [official Apple network_cmds $NETWORK_CMDS_VERSION, framework]"
}

# ---- ping: Apple network_cmds (BSD/Darwin), built without source patches ----
# toybox ping is Linux-only (IP_RECVTTL, struct icmphdr, millitime-based RTT
# truncated to unsigned short). Apple's official ping uses SOCK_DGRAM ICMP with
# gettimeofday-based RTT (struct tv32, network byte order), which is correct on
# Darwin. SO_TRAFFIC_CLASS is a private kernel API absent from the iOS SDK; stub
# it to 0 — the traffic-class codepath becomes a harmless no-op setsockopt.

build_ping_slice() {  # out plat
  local out="$1"; local plat="$2"
  fetch_network_cmds_sources

  local sdk arch minv macsdk kern cc d src
  sdk="$(xcrun --sdk "$plat" --show-sdk-path)"
  cc="$(xcrun -f clang)"
  if [ "$plat" = iphoneos ]; then
    arch=arm64
    minv="-miphoneos-version-min=15.0"
  else
    arch="$(uname -m)"
    minv="-mios-simulator-version-min=15.0"
  fi
  macsdk="$(xcrun --sdk macosx --show-sdk-path)"
  kern="$macsdk/System/Library/Frameworks/Kernel.framework/Versions/A/Headers"
  d="$(dirname "$out")"
  src="$BUILD/network_cmds/network_cmds-$plat-src"

  rm -rf "$src"; mkdir -p "$src"
  tar -xf "$NETWORK_CMDS_TARBALL" -C "$src" --strip-components 1

  "$cc" -isysroot "$sdk" -arch "$arch" $minv -I "$INCLUDE" \
    -c "$CRT/micro_os_crt.c" -o "$d/ping-crt.o"
  "$cc" -isysroot "$sdk" -arch "$arch" $minv -I "$INCLUDE" \
    -c "$CRT/micro_os_libc_shim.c" -o "$d/ping-libc.o"

  local abi_parent
  abi_parent="$(microosabi_framework_parent "$plat")" || return 1
  local base_flags=(-isysroot "$sdk" -arch "$arch" $minv
    -I "$INCLUDE"
    -idirafter "$kern" -idirafter "$macsdk/usr/include")
  local prog_flags=("${base_flags[@]}"
    -Dmain=entry -include micro_os_crt.h
    -DSO_TRAFFIC_CLASS=0 -Wno-deprecated-non-prototype)

  "$cc" -c "${prog_flags[@]}" "$src/ping.tproj/ping.c" -o "$d/ping-ping.o"

  "$cc" -dynamiclib -isysroot "$sdk" -arch "$arch" $minv \
    "$d/ping-crt.o" "$d/ping-libc.o" "$d/ping-ping.o" \
    -F "$abi_parent" -framework MicroOSABI -lm -o "$out"
}

build_ping_xcframework() {
  fetch_network_cmds_sources || return 1
  fws=()
  for plat in $PLATFORMS; do
    mkdir -p "$BUILD/$plat"
    slice="$BUILD/$plat/ping.dylib"
    echo "  building ping slice: $plat"
    build_ping_slice "$slice" "$plat" || return 1
    fw="$BUILD/$plat/ping.framework"
    make_framework "$slice" "$fw" "ping" "$plat"
    fws+=(-framework "$fw")
  done
  rm -rf "$OUT/ping.xcframework"
  xcrun xcodebuild -create-xcframework "${fws[@]}" -output "$OUT/ping.xcframework" >/dev/null
  echo "built ping -> payload/ping.xcframework ($PLATFORMS) [official Apple network_cmds $NETWORK_CMDS_VERSION, framework]"
}

# ---- zip/unzip: official Info-ZIP source, built without source patches ----
ZIP_VERSION="${ZIP_VERSION:-3.0}"
ZIP_SHA256="${ZIP_SHA256:-f0e8bb1f9b7eb0b01285495a2699df3a4b766784c1765a8f1aeedf63c0806369}"
UNZIP_VERSION="${UNZIP_VERSION:-6.0}"
UNZIP_SHA256="${UNZIP_SHA256:-036d96991646d0449ed0aa952e4fbe21b476ce994abc276e49d30e686708bd37}"

fetch_infozip_sources() {
  ZIP_TARBALL="$BUILD/infozip/zip30.tar.gz"
  UNZIP_TARBALL="$BUILD/infozip/unzip60.tar.gz"
  fetch_verified_tarball zip "$ZIP_VERSION" \
    "https://sourceforge.net/projects/infozip/files/Zip%203.x%20%28latest%29/3.0/zip30.tar.gz/download" \
    "$ZIP_SHA256" "$ZIP_TARBALL"
  fetch_verified_tarball unzip "$UNZIP_VERSION" \
    "https://sourceforge.net/projects/infozip/files/UnZip%206.x%20%28latest%29/UnZip%206.0/unzip60.tar.gz/download" \
    "$UNZIP_SHA256" "$UNZIP_TARBALL"
}

build_zip_slice() {  # out plat
  local out="$1"; local plat="$2"
  fetch_infozip_sources
  curl_platform_vars "$plat"

  local cc d src objdir objects file obj abi_parent
  cc="$(xcrun -f clang)"
  d="$(dirname "$out")"
  abi_parent="$(microosabi_framework_parent "$plat")" || return 1
  src="$BUILD/infozip/zip-$plat-src"
  objdir="$BUILD/infozip/zip-$plat-obj"
  rm -rf "$src" "$objdir"; mkdir -p "$src" "$objdir"
  tar -xzf "$ZIP_TARBALL" -C "$src" --strip-components 1

  "$cc" -c $target_flags -I "$INCLUDE" "$CRT/micro_os_crt.c" -o "$d/zip-crt.o"
  "$cc" -c $target_flags -I "$INCLUDE" "$CRT/micro_os_libc_shim.c" -o "$d/zip-libc.o"

  objects=("$d/zip-crt.o" "$d/zip-libc.o")
  for file in zip.c zipfile.c zipup.c fileio.c util.c globals.c crypt.c ttyio.c \
              unix/unix.c crc32.c zbz2err.c deflate.c trees.c; do
    obj="$objdir/${file//\//_}.o"
    "$cc" -c $target_flags -fPIC -DUNIX -Dmain=entry \
      -Wno-implicit-function-declaration -Wno-deprecated-non-prototype -Wno-int-conversion \
      -I "$INCLUDE" -I "$src" -I "$src/unix" -include micro_os_crt.h \
      "$src/$file" -o "$obj"
    objects+=("$obj")
  done

  "$cc" -dynamiclib $target_flags "${objects[@]}" \
    -F "$abi_parent" -framework MicroOSABI -o "$out"
}

build_unzip_slice() {  # out plat
  local out="$1"; local plat="$2"
  fetch_infozip_sources
  curl_platform_vars "$plat"

  local cc d src objdir objects file obj abi_parent
  cc="$(xcrun -f clang)"
  d="$(dirname "$out")"
  abi_parent="$(microosabi_framework_parent "$plat")" || return 1
  src="$BUILD/infozip/unzip-$plat-src"
  objdir="$BUILD/infozip/unzip-$plat-obj"
  rm -rf "$src" "$objdir"; mkdir -p "$src" "$objdir"
  tar -xzf "$UNZIP_TARBALL" -C "$src" --strip-components 1

  "$cc" -c $target_flags -I "$INCLUDE" "$CRT/micro_os_crt.c" -o "$d/unzip-crt.o"
  "$cc" -c $target_flags -I "$INCLUDE" "$CRT/micro_os_libc_shim.c" -o "$d/unzip-libc.o"

  objects=("$d/unzip-crt.o" "$d/unzip-libc.o")
  for file in unzip.c crc32.c crypt.c envargs.c explode.c extract.c fileio.c globals.c \
              inflate.c list.c match.c process.c ttyio.c ubz2err.c unreduce.c \
              unshrink.c zipinfo.c unix/unix.c; do
    obj="$objdir/${file//\//_}.o"
    "$cc" -c $target_flags -fPIC -DUNIX -Dmain=entry \
      -Wno-implicit-function-declaration -Wno-deprecated-non-prototype -Wno-int-conversion \
      -I "$INCLUDE" -I "$src" -I "$src/unix" -include micro_os_crt.h \
      "$src/$file" -o "$obj"
    objects+=("$obj")
  done

  "$cc" -dynamiclib $target_flags "${objects[@]}" \
    -F "$abi_parent" -framework MicroOSABI -o "$out"
}

build_infozip_xcframework() {
  local name="$1"; local buildfn="$2"
  fetch_infozip_sources || return 1
  fws=()
  for plat in $PLATFORMS; do
    mkdir -p "$BUILD/$plat"
    slice="$BUILD/$plat/$name.dylib"
    echo "  building $name slice: $plat"
    "$buildfn" "$slice" "$plat" || return 1
    fw="$BUILD/$plat/$name.framework"
    make_framework "$slice" "$fw" "$name" "$plat"
    fws+=(-framework "$fw")
  done
  rm -rf "$OUT/$name.xcframework"
  xcrun xcodebuild -create-xcframework "${fws[@]}" -output "$OUT/$name.xcframework" >/dev/null
  echo "built $name -> payload/$name.xcframework ($PLATFORMS) [official Info-ZIP, framework]"
}

# ---- zlib/gzip/xz/bzip2/less/awk: official sources, built without source patches ----
# gzip and more are upstream toybox applets enabled in the system toybox build.
# zlib is shipped as a dynamic framework for programs that want libz, not as a
# shell command.
ZLIB_VERSION="${ZLIB_VERSION:-1.3.1}"
ZLIB_SHA256="${ZLIB_SHA256:-9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23}"
XZ_VERSION="${XZ_VERSION:-5.8.1}"
XZ_SHA256="${XZ_SHA256:-0b54f79df85912504de0b14aec7971e3f964491af1812d83447005807513cd9e}"
BZIP2_VERSION="${BZIP2_VERSION:-1.0.8}"
BZIP2_SHA256="${BZIP2_SHA256:-ab5a03176ee106d3f0fa90e381da478ddae405918153cca248e682cd0c4a2269}"
LESS_VERSION="${LESS_VERSION:-679}"
LESS_SHA256="${LESS_SHA256:-9b68820c34fa8a0af6b0e01b74f0298bcdd40a0489c61649b47058908a153d78}"
AWK_VERSION="${AWK_VERSION:-20250116}"
AWK_SHA256="${AWK_SHA256:-e031b1e1d2b230f276f975bffb923f0ea15f798c839d15a3f26a1a39448e32d7}"
LIBBZ2_INSTALL_NAME="@loader_path/../libbz2.framework/libbz2"
LIBLZMA_INSTALL_NAME="@loader_path/../liblzma.framework/liblzma"

fetch_zlib_source() {
  ZLIB_TARBALL="$BUILD/zlib/zlib-$ZLIB_VERSION.tar.gz"
  fetch_verified_tarball zlib "$ZLIB_VERSION" \
    "https://zlib.net/fossils/zlib-$ZLIB_VERSION.tar.gz" \
    "$ZLIB_SHA256" "$ZLIB_TARBALL"
}

build_zlib_slice() {  # out plat
  local out="$1"; local plat="$2"
  fetch_zlib_source
  curl_platform_vars "$plat"

  local cc d src objdir objects file obj abi_parent
  cc="$(xcrun -f clang)"
  d="$(dirname "$out")"
  abi_parent="$(microosabi_framework_parent "$plat")" || return 1
  src="$BUILD/zlib/zlib-$plat-src"
  objdir="$BUILD/zlib/zlib-$plat-obj"
  rm -rf "$src" "$objdir"; mkdir -p "$src" "$objdir"
  tar -xzf "$ZLIB_TARBALL" -C "$src" --strip-components 1

  "$cc" -c $target_flags -I "$INCLUDE" "$CRT/micro_os_libc_shim.c" -o "$d/zlib-libc.o"
  objects=("$d/zlib-libc.o")
  for file in adler32.c compress.c crc32.c deflate.c gzclose.c gzlib.c gzread.c \
              gzwrite.c infback.c inffast.c inflate.c inftrees.c trees.c \
              uncompr.c zutil.c; do
    obj="$objdir/${file%.c}.o"
    "$cc" -c $target_flags -fPIC -Wno-implicit-function-declaration \
      -I "$INCLUDE" -I "$src" "$src/$file" -o "$obj"
    objects+=("$obj")
  done

  "$cc" -dynamiclib $target_flags "${objects[@]}" \
    -F "$abi_parent" -framework MicroOSABI -o "$out"
}

build_zlib_xcframework() {
  fetch_zlib_source || return 1
  fws=()
  for plat in $PLATFORMS; do
    mkdir -p "$BUILD/$plat"
    slice="$BUILD/$plat/zlib.dylib"
    echo "  building zlib slice: $plat"
    build_zlib_slice "$slice" "$plat" || return 1
    fw="$BUILD/$plat/zlib.framework"
    make_framework "$slice" "$fw" "zlib" "$plat"
    fws+=(-framework "$fw")
  done
  rm -rf "$OUT/zlib.xcframework"
  xcrun xcodebuild -create-xcframework "${fws[@]}" -output "$OUT/zlib.xcframework" >/dev/null
  echo "built zlib -> payload/zlib.xcframework ($PLATFORMS) [official zlib $ZLIB_VERSION, framework]"
}

fetch_xz_source() {
  XZ_TARBALL="$BUILD/xz/xz-$XZ_VERSION.tar.xz"
  fetch_verified_tarball xz "$XZ_VERSION" \
    "https://tukaani.org/xz/xz-$XZ_VERSION.tar.xz" \
    "$XZ_SHA256" "$XZ_TARBALL"
}

build_xz_lzma_slice_set() {  # plat product_dir
  local plat="$1"; local products="$2"
  fetch_xz_source
  curl_platform_vars "$plat"

  local cc d src bld abi_parent
  cc="$(xcrun -f clang)"
  d="$products"
  abi_parent="$(microosabi_framework_parent "$plat")" || return 1
  src="$BUILD/xz/xz-$plat-src"
  bld="$BUILD/xz/xz-$plat-build"
  rm -rf "$src" "$bld" "$products"; mkdir -p "$src" "$bld" "$products"
  tar -xf "$XZ_TARBALL" -C "$src" --strip-components 1

  "$cc" -c $target_flags -I "$INCLUDE" "$CRT/micro_os_crt.c" -o "$d/xz-crt.o"
  "$cc" -c $target_flags -I "$INCLUDE" "$CRT/micro_os_libc_shim.c" -o "$d/xz-libc.o"
  cmake -S "$src" -B "$bld" -G "Unix Makefiles" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="$sdk" \
    -DCMAKE_OSX_ARCHITECTURES="$arch" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
    -DCMAKE_C_COMPILER="$cc" \
    -DCMAKE_C_FLAGS="$target_flags -fPIC -I$INCLUDE -include $INCLUDE/micro_os_crt.h" \
    -DCMAKE_SHARED_LINKER_FLAGS="$target_flags -F$abi_parent -framework MicroOSABI" \
    -DCMAKE_EXE_LINKER_FLAGS="$target_flags -dynamiclib -Wl,-alias,_main,_entry $d/xz-crt.o $d/xz-libc.o -F$abi_parent -framework MicroOSABI" \
    -DBUILD_SHARED_LIBS=ON \
    -DXZ_TOOL_XZ=ON \
    -DXZ_TOOL_XZDEC=OFF \
    -DXZ_TOOL_LZMADEC=OFF \
    -DXZ_TOOL_LZMAINFO=OFF \
    -DXZ_NLS=OFF \
    -DXZ_THREADS=no
  cmake --build "$bld" --target xz --parallel "${MAKE_JOBS:-2}"
  cp -f "$bld/xz" "$products/xz.dylib"
  cp -f "$bld/liblzma.dylib" "$products/liblzma.dylib"
  xcrun install_name_tool -id "$LIBLZMA_INSTALL_NAME" "$products/liblzma.dylib" 2>/dev/null || true
  xcrun install_name_tool -change "$bld/liblzma.dylib" "$LIBLZMA_INSTALL_NAME" "$products/xz.dylib" 2>/dev/null || true
  xcrun install_name_tool -change "@rpath/liblzma.dylib" "$LIBLZMA_INSTALL_NAME" "$products/xz.dylib" 2>/dev/null || true
  xcrun install_name_tool -change "@rpath/liblzma.5.dylib" "$LIBLZMA_INSTALL_NAME" "$products/xz.dylib" 2>/dev/null || true
}

build_xz_xcframework() {
  fetch_xz_source || return 1
  local names=(liblzma xz)
  local name plat products fw
  for plat in $PLATFORMS; do
    products="$BUILD/xz/products-$plat"
    echo "  building xz/liblzma slice set: $plat"
    build_xz_lzma_slice_set "$plat" "$products" || return 1
    for name in "${names[@]}"; do
      fw="$BUILD/xz/$plat/$name.framework"
      make_framework "$products/$name.dylib" "$fw" "$name" "$plat"
    done
  done
  for name in "${names[@]}"; do
    local fws=()
    for plat in $PLATFORMS; do
      fws+=(-framework "$BUILD/xz/$plat/$name.framework")
    done
    rm -rf "$OUT/$name.xcframework"
    xcrun xcodebuild -create-xcframework "${fws[@]}" -output "$OUT/$name.xcframework" >/dev/null
    echo "built $name -> payload/$name.xcframework ($PLATFORMS) [official xz $XZ_VERSION, framework]"
  done
}

fetch_bzip2_source() {
  BZIP2_TARBALL="$BUILD/bzip2/bzip2-$BZIP2_VERSION.tar.gz"
  fetch_verified_tarball bzip2 "$BZIP2_VERSION" \
    "https://sourceware.org/pub/bzip2/bzip2-$BZIP2_VERSION.tar.gz" \
    "$BZIP2_SHA256" "$BZIP2_TARBALL"
}

build_bzip2_slice_set() {  # plat product_dir
  local plat="$1"; local products="$2"
  fetch_bzip2_source
  curl_platform_vars "$plat"

  local cc d src objdir objects file obj abi_parent
  cc="$(xcrun -f clang)"
  d="$products"
  abi_parent="$(microosabi_framework_parent "$plat")" || return 1
  src="$BUILD/bzip2/bzip2-$plat-src"
  objdir="$BUILD/bzip2/bzip2-$plat-obj"
  rm -rf "$src" "$objdir" "$products"; mkdir -p "$src" "$objdir" "$products"
  tar -xzf "$BZIP2_TARBALL" -C "$src" --strip-components 1

  "$cc" -c $target_flags -I "$INCLUDE" "$CRT/micro_os_crt.c" -o "$d/bzip2-crt.o"
  "$cc" -c $target_flags -I "$INCLUDE" "$CRT/micro_os_libc_shim.c" -o "$d/bzip2-libc.o"
  local lib_objects=()
  for file in blocksort.c huffman.c crctable.c randtable.c compress.c \
              decompress.c bzlib.c; do
    obj="$objdir/${file%.c}.o"
    "$cc" -c $target_flags -fPIC -I "$INCLUDE" -I "$src" "$src/$file" -o "$obj"
    lib_objects+=("$obj")
  done

  "$cc" -dynamiclib $target_flags "${lib_objects[@]}" \
    -install_name "$LIBBZ2_INSTALL_NAME" -o "$products/libbz2.dylib"

  obj="$objdir/bzip2.o"
  "$cc" -c $target_flags -fPIC -Dmain=entry \
    -I "$INCLUDE" -I "$src" -include micro_os_crt.h \
    "$src/bzip2.c" -o "$obj"
  "$cc" -dynamiclib $target_flags "$d/bzip2-crt.o" "$d/bzip2-libc.o" "$obj" \
    "$products/libbz2.dylib" -F "$abi_parent" -framework MicroOSABI \
    -o "$products/bzip2.dylib"
  xcrun install_name_tool -change "$products/libbz2.dylib" "$LIBBZ2_INSTALL_NAME" "$products/bzip2.dylib" 2>/dev/null || true
}

build_bzip2_xcframework() {
  fetch_bzip2_source || return 1
  local names=(libbz2 bzip2)
  local name plat products fw
  for plat in $PLATFORMS; do
    products="$BUILD/bzip2/products-$plat"
    echo "  building bzip2/libbz2 slice set: $plat"
    build_bzip2_slice_set "$plat" "$products" || return 1
    for name in "${names[@]}"; do
      fw="$BUILD/bzip2/$plat/$name.framework"
      make_framework "$products/$name.dylib" "$fw" "$name" "$plat"
    done
  done
  for name in "${names[@]}"; do
    local fws=()
    for plat in $PLATFORMS; do
      fws+=(-framework "$BUILD/bzip2/$plat/$name.framework")
    done
    rm -rf "$OUT/$name.xcframework"
    xcrun xcodebuild -create-xcframework "${fws[@]}" -output "$OUT/$name.xcframework" >/dev/null
    echo "built $name -> payload/$name.xcframework ($PLATFORMS) [official bzip2 $BZIP2_VERSION, framework]"
  done
}

fetch_less_source() {
  LESS_TARBALL="$BUILD/less/less-$LESS_VERSION.tar.gz"
  fetch_verified_tarball less "$LESS_VERSION" \
    "https://www.greenwoodsoftware.com/less/less-$LESS_VERSION.tar.gz" \
    "$LESS_SHA256" "$LESS_TARBALL"
}

write_less_termcap_shim() {  # path
  cat > "$1" <<'EOF'
#include <stddef.h>
#include <stdio.h>
#include <string.h>

char mols_tc_pc;
short mols_tc_speed;

static char *mols_tc_copy(const char *value, char **area) {
  size_t len;
  char *dst;

  if (value == NULL) return NULL;
  if (area == NULL || *area == NULL) return (char *) value;
  len = strlen(value) + 1;
  dst = *area;
  memcpy(dst, value, len);
  *area += len;
  return dst;
}

int mols_tc_ent(char *buffer, const char *name) {
  (void) buffer;
  (void) name;
  return 1;
}

int mols_tc_flag(const char *id) {
  if (id == NULL) return 0;
  return strcmp(id, "am") == 0 || strcmp(id, "bs") == 0 || strcmp(id, "ut") == 0;
}

int mols_tc_num(const char *id) {
  if (id == NULL) return -1;
  if (strcmp(id, "li") == 0) return 24;
  if (strcmp(id, "co") == 0) return 80;
  if (strcmp(id, "sg") == 0) return 0;
  return -1;
}

char *mols_tc_str(const char *id, char **area) {
  if (id == NULL) return NULL;
  if (strcmp(id, "cl") == 0) return mols_tc_copy("\033[H\033[2J", area);
  if (strcmp(id, "ce") == 0) return mols_tc_copy("\033[K", area);
  if (strcmp(id, "cd") == 0) return mols_tc_copy("\033[J", area);
  if (strcmp(id, "cm") == 0) return mols_tc_copy("\033[%i%d;%dH", area);
  if (strcmp(id, "ho") == 0) return mols_tc_copy("\033[H", area);
  if (strcmp(id, "cr") == 0) return mols_tc_copy("\r", area);
  if (strcmp(id, "bc") == 0 || strcmp(id, "kb") == 0) return mols_tc_copy("\b", area);
  if (strcmp(id, "so") == 0 || strcmp(id, "md") == 0) return mols_tc_copy("\033[7m", area);
  if (strcmp(id, "se") == 0 || strcmp(id, "me") == 0) return mols_tc_copy("\033[0m", area);
  if (strcmp(id, "us") == 0) return mols_tc_copy("\033[4m", area);
  if (strcmp(id, "ue") == 0) return mols_tc_copy("\033[24m", area);
  if (strcmp(id, "mb") == 0) return mols_tc_copy("\033[5m", area);
  if (strcmp(id, "vb") == 0) return mols_tc_copy("\007", area);
  if (strcmp(id, "ku") == 0) return mols_tc_copy("\033[A", area);
  if (strcmp(id, "kd") == 0) return mols_tc_copy("\033[B", area);
  if (strcmp(id, "kr") == 0) return mols_tc_copy("\033[C", area);
  if (strcmp(id, "kl") == 0) return mols_tc_copy("\033[D", area);
  if (strcmp(id, "kP") == 0) return mols_tc_copy("\033[5~", area);
  if (strcmp(id, "kN") == 0) return mols_tc_copy("\033[6~", area);
  if (strcmp(id, "kh") == 0) return mols_tc_copy("\033[H", area);
  if (strcmp(id, "@7") == 0) return mols_tc_copy("\033[F", area);
  if (strcmp(id, "kD") == 0) return mols_tc_copy("\033[3~", area);
  if (strcmp(id, "@8") == 0) return mols_tc_copy("\r", area);
  if (strcmp(id, "ks") == 0 || strcmp(id, "ke") == 0) return mols_tc_copy("", area);
  if (strcmp(id, "ti") == 0 || strcmp(id, "te") == 0) return mols_tc_copy("", area);
  if (strcmp(id, "pc") == 0) return mols_tc_copy("", area);
  return NULL;
}

char *mols_tc_go(const char *cm, int col, int row) {
  static char buffer[32];
  (void) cm;
  snprintf(buffer, sizeof(buffer), "\033[%d;%dH", row + 1, col + 1);
  return buffer;
}

int mols_tc_put(const char *str, int affcnt, int (*putc_fn)(int)) {
  (void) affcnt;
  if (str == NULL || putc_fn == NULL) return 0;
  while (*str != '\0') {
    putc_fn((unsigned char) *str);
    ++str;
  }
  return 0;
}
EOF
}

build_less_slice() {  # out plat
  local out="$1"; local plat="$2"
  fetch_less_source
  curl_platform_vars "$plat"

  local cc d src macsdk abi_parent termcap_c termcap_o termcap_renames
  cc="$(xcrun -f clang)"
  d="$(dirname "$out")"
  abi_parent="$(microosabi_framework_parent "$plat")" || return 1
  macsdk="$(xcrun --sdk macosx --show-sdk-path)"
  src="$BUILD/less/less-$plat-src"
  rm -rf "$src"; mkdir -p "$src"
  tar -xzf "$LESS_TARBALL" -C "$src" --strip-components 1

  "$cc" -c $target_flags -I "$INCLUDE" "$CRT/micro_os_crt.c" -o "$d/less-crt.o"
  "$cc" -c $target_flags -I "$INCLUDE" "$CRT/micro_os_libc_shim.c" -o "$d/less-libc.o"
  termcap_c="$d/less-termcap-shim.c"
  termcap_o="$d/less-termcap-shim.o"
  write_less_termcap_shim "$termcap_c"
  "$cc" -c $target_flags -fPIC "$termcap_c" -o "$termcap_o"
  termcap_renames="-Dtgetent=mols_tc_ent -Dtgetflag=mols_tc_flag -Dtgetnum=mols_tc_num -Dtgetstr=mols_tc_str -Dtgoto=mols_tc_go -Dtputs=mols_tc_put -DPC=mols_tc_pc -Dospeed=mols_tc_speed"
  (
    cd "$src"
    env \
      CC="$cc" \
      CFLAGS="$target_flags -fPIC -I$INCLUDE -idirafter $macsdk/usr/include -include micro_os_crt.h -DREGEX_MALLOC=1 $termcap_renames" \
      CPPFLAGS="-I$INCLUDE -idirafter $macsdk/usr/include $termcap_renames" \
      LDFLAGS="$target_flags" \
      LIBS="$termcap_o" \
      ./configure --host="$host" --with-regex=posix --with-secure
    make -j"${MAKE_JOBS:-2}" less \
      LIBS="$termcap_o" \
      LDFLAGS="$target_flags -dynamiclib -Wl,-alias,_main,_entry $d/less-crt.o $d/less-libc.o -F$abi_parent -framework MicroOSABI"
    cp -f less "$out"
  ) || return 1
  validate_absent_global_symbols "$out" "less-$plat" \
    _PC _ospeed _tgetent _tgetflag _tgetnum _tgetstr _tgoto _tputs
}

build_less_xcframework() {
  fetch_less_source || return 1
  fws=()
  for plat in $PLATFORMS; do
    mkdir -p "$BUILD/$plat"
    slice="$BUILD/$plat/less.dylib"
    echo "  building less slice: $plat"
    build_less_slice "$slice" "$plat" || return 1
    fw="$BUILD/$plat/less.framework"
    make_framework "$slice" "$fw" "less" "$plat"
    fws+=(-framework "$fw")
  done
  rm -rf "$OUT/less.xcframework"
  xcrun xcodebuild -create-xcframework "${fws[@]}" -output "$OUT/less.xcframework" >/dev/null
  echo "built less -> payload/less.xcframework ($PLATFORMS) [official less $LESS_VERSION, framework]"
}

fetch_awk_source() {
  AWK_TARBALL="$BUILD/awk/awk-$AWK_VERSION.tar.gz"
  fetch_verified_tarball awk "$AWK_VERSION" \
    "https://github.com/onetrueawk/awk/archive/refs/tags/$AWK_VERSION.tar.gz" \
    "$AWK_SHA256" "$AWK_TARBALL"
}

build_awk_slice() {  # out plat
  local out="$1"; local plat="$2"
  fetch_awk_source
  curl_platform_vars "$plat"

  local cc d src objdir objects file obj abi_parent
  cc="$(xcrun -f clang)"
  d="$(dirname "$out")"
  abi_parent="$(microosabi_framework_parent "$plat")" || return 1
  src="$BUILD/awk/awk-$plat-src"
  objdir="$BUILD/awk/awk-$plat-obj"
  rm -rf "$src" "$objdir"; mkdir -p "$src" "$objdir"
  tar -xzf "$AWK_TARBALL" -C "$src" --strip-components 1
  (
    cd "$src"
    make -f makefile HOSTCC=cc CC=cc CFLAGS= awkgram.tab.c awkgram.tab.h proctab.c
  ) || return 1

  "$cc" -c $target_flags -I "$INCLUDE" "$CRT/micro_os_crt.c" -o "$d/awk-crt.o"
  "$cc" -c $target_flags -I "$INCLUDE" "$CRT/micro_os_libc_shim.c" -o "$d/awk-libc.o"
  objects=("$d/awk-crt.o" "$d/awk-libc.o")
  for file in awkgram.tab.c b.c main.c parse.c proctab.c tran.c lib.c run.c lex.c; do
    obj="$objdir/${file%.c}.o"
    "$cc" -c $target_flags -fPIC -Dmain=entry \
      -I "$INCLUDE" -I "$src" -include micro_os_crt.h \
      "$src/$file" -o "$obj"
    objects+=("$obj")
  done

  "$cc" -dynamiclib $target_flags "${objects[@]}" -lm \
    -F "$abi_parent" -framework MicroOSABI -o "$out"
}

build_awk_xcframework() {
  fetch_awk_source || return 1
  fws=()
  for plat in $PLATFORMS; do
    mkdir -p "$BUILD/$plat"
    slice="$BUILD/$plat/awk.dylib"
    echo "  building awk slice: $plat"
    build_awk_slice "$slice" "$plat" || return 1
    fw="$BUILD/$plat/awk.framework"
    make_framework "$slice" "$fw" "awk" "$plat"
    fws+=(-framework "$fw")
  done
  rm -rf "$OUT/awk.xcframework"
  xcrun xcodebuild -create-xcframework "${fws[@]}" -output "$OUT/awk.xcframework" >/dev/null
  echo "built awk -> payload/awk.xcframework ($PLATFORMS) [official One True Awk $AWK_VERSION, framework]"
}

build_traceroute_slice() {  # out plat
  local out="$1"; local plat="$2"
  fetch_network_cmds_sources
  curl_platform_vars "$plat"

  local cc d src objdir compat macsdk objects file obj abi_parent
  cc="$(xcrun -f clang)"
  d="$(dirname "$out")"
  abi_parent="$(microosabi_framework_parent "$plat")" || return 1
  macsdk="$(xcrun --sdk macosx --show-sdk-path)"
  src="$BUILD/network_cmds/traceroute-$plat-src"
  objdir="$BUILD/network_cmds/traceroute-$plat-obj"
  compat="$BUILD/network_cmds/traceroute-$plat-compat"
  rm -rf "$src" "$objdir" "$compat"; mkdir -p "$src" "$objdir" "$compat/net"
  tar -xzf "$NETWORK_CMDS_TARBALL" -C "$src" --strip-components 1
  cp "$macsdk/usr/include/net/route.h" "$compat/net/route.h"

  "$cc" -c $target_flags -I "$INCLUDE" "$CRT/micro_os_crt.c" -o "$d/traceroute-crt.o"
  "$cc" -c $target_flags -I "$INCLUDE" "$CRT/micro_os_libc_shim.c" -o "$d/traceroute-libc.o"
  objects=("$d/traceroute-crt.o" "$d/traceroute-libc.o")
  for file in traceroute.c ifaddrlist.c findsaddr-socket.c as.c version.c; do
    obj="$objdir/${file%.c}.o"
    "$cc" -c $target_flags -fPIC -Dmain=entry \
      -I "$compat" -I "$INCLUDE" -I "$src/traceroute.tproj" \
      -idirafter "$macsdk/usr/include" -include micro_os_crt.h \
      -Wno-deprecated-non-prototype -Wno-implicit-function-declaration -Wno-int-conversion \
      "$src/traceroute.tproj/$file" -o "$obj"
    objects+=("$obj")
  done

  "$cc" -dynamiclib $target_flags "${objects[@]}" \
    -F "$abi_parent" -framework MicroOSABI -o "$out"
}

build_traceroute_xcframework() {
  fetch_network_cmds_sources || return 1
  fws=()
  for plat in $PLATFORMS; do
    mkdir -p "$BUILD/$plat"
    slice="$BUILD/$plat/traceroute.dylib"
    echo "  building traceroute slice: $plat"
    build_traceroute_slice "$slice" "$plat" || return 1
    fw="$BUILD/$plat/traceroute.framework"
    make_framework "$slice" "$fw" "traceroute" "$plat"
    fws+=(-framework "$fw")
  done
  rm -rf "$OUT/traceroute.xcframework"
  xcrun xcodebuild -create-xcframework "${fws[@]}" -output "$OUT/traceroute.xcframework" >/dev/null
  echo "built traceroute -> payload/traceroute.xcframework ($PLATFORMS) [official Apple network_cmds $NETWORK_CMDS_VERSION, framework]"
}

# ---- whois: official FreeBSD usr.bin/whois source, built without source patches ----
WHOIS_VERSION="${WHOIS_VERSION:-freebsd-14.3}"
WHOIS_SHA256="${WHOIS_SHA256:-2145be939860e72b3a3a3c4ee759e55ff16ee794dd32b1a9f604a4338680f05d}"

fetch_whois_source() {
  WHOIS_SOURCE="$BUILD/whois/whois-$WHOIS_VERSION.c"
  fetch_verified_file whois "$WHOIS_VERSION" \
    "https://raw.githubusercontent.com/freebsd/freebsd-src/releng/14.3/usr.bin/whois/whois.c" \
    "$WHOIS_SHA256" "$WHOIS_SOURCE"
}

build_whois_slice() {  # out plat
  local out="$1"; local plat="$2"
  fetch_whois_source
  curl_platform_vars "$plat"

  local cc d abi_parent
  cc="$(xcrun -f clang)"
  d="$(dirname "$out")"
  abi_parent="$(microosabi_framework_parent "$plat")" || return 1
  "$cc" -c $target_flags -I "$INCLUDE" "$CRT/micro_os_crt.c" -o "$d/whois-crt.o"
  "$cc" -c $target_flags -I "$INCLUDE" "$CRT/micro_os_libc_shim.c" -o "$d/whois-libc.o"
  "$cc" -dynamiclib $target_flags \
    -Dmain=entry -DSOCK_NONBLOCK=0 -DINFTIM=-1 \
    '-D__printflike(a,b)=' '-D__dead2=__attribute__((noreturn))' \
    -Wno-implicit-function-declaration -Wno-deprecated-non-prototype -Wno-int-conversion \
    -I "$INCLUDE" -include micro_os_crt.h \
    "$WHOIS_SOURCE" "$d/whois-crt.o" "$d/whois-libc.o" \
    -F "$abi_parent" -framework MicroOSABI -o "$out"
}

build_whois_xcframework() {
  fetch_whois_source || return 1
  fws=()
  for plat in $PLATFORMS; do
    mkdir -p "$BUILD/$plat"
    slice="$BUILD/$plat/whois.dylib"
    echo "  building whois slice: $plat"
    build_whois_slice "$slice" "$plat" || return 1
    fw="$BUILD/$plat/whois.framework"
    make_framework "$slice" "$fw" "whois" "$plat"
    fws+=(-framework "$fw")
  done
  rm -rf "$OUT/whois.xcframework"
  xcrun xcodebuild -create-xcframework "${fws[@]}" -output "$OUT/whois.xcframework" >/dev/null
  echo "built whois -> payload/whois.xcframework ($PLATFORMS) [official FreeBSD $WHOIS_VERSION, framework]"
}

# ---- uptime: official Apple shell_cmds w(1), compiled as uptime(1) ----
SHELL_CMDS_VERSION="${SHELL_CMDS_VERSION:-shell_cmds-329}"
APPLE_W_SHA256="${APPLE_W_SHA256:-b22a5e394ee05c703ccdfb0a10f8ab0e95e3f59da3794ecfcefbaf916bdaa174}"
APPLE_W_EXTERN_SHA256="${APPLE_W_EXTERN_SHA256:-11de62e81883bed65fed675ea61a683e7043ebcb88dbfe66193f65c976baf544}"
APPLE_W_PR_TIME_SHA256="${APPLE_W_PR_TIME_SHA256:-0afab7b2fb50785653b1ef073e73efb685082de6f4317b7feb08d898feb89c68}"
APPLE_W_PROC_COMPARE_SHA256="${APPLE_W_PROC_COMPARE_SHA256:-cc5858de47e5d0acc9ad4e6f40d97ae8ad35ab56499124e264665cabe2723235}"
LIBXO_VERSION="${LIBXO_VERSION:-1.7.5}"
LIBXO_SHA256="${LIBXO_SHA256:-a4d3bd1cbbbfe7de6dad7a7e6f87757f9881753eb32d6ce6894e00e6eb28f841}"
APPLE_LIBUTIL_VERSION="${APPLE_LIBUTIL_VERSION:-libutil-73}"
APPLE_LIBUTIL_H_SHA256="${APPLE_LIBUTIL_H_SHA256:-edf761285ccde9059b573a3056f3d598a9a3ae6ed8814e16ae202f07b52c174c}"

fetch_apple_w_sources() {
  APPLE_W_SOURCE="$BUILD/apple-shell-cmds/w-$SHELL_CMDS_VERSION.c"
  APPLE_W_EXTERN="$BUILD/apple-shell-cmds/extern-$SHELL_CMDS_VERSION.h"
  APPLE_W_PR_TIME="$BUILD/apple-shell-cmds/pr_time-$SHELL_CMDS_VERSION.c"
  APPLE_W_PROC_COMPARE="$BUILD/apple-shell-cmds/proc_compare-$SHELL_CMDS_VERSION.c"
  LIBXO_TARBALL="$BUILD/libxo/libxo-$LIBXO_VERSION.tar.gz"
  APPLE_LIBUTIL_H="$BUILD/apple-libutil/libutil-$APPLE_LIBUTIL_VERSION.h"
  fetch_verified_file apple-shell-cmds "$SHELL_CMDS_VERSION-w.c" \
    "https://raw.githubusercontent.com/apple-oss-distributions/shell_cmds/$SHELL_CMDS_VERSION/w/w.c" \
    "$APPLE_W_SHA256" "$APPLE_W_SOURCE"
  fetch_verified_file apple-shell-cmds "$SHELL_CMDS_VERSION-extern.h" \
    "https://raw.githubusercontent.com/apple-oss-distributions/shell_cmds/$SHELL_CMDS_VERSION/w/extern.h" \
    "$APPLE_W_EXTERN_SHA256" "$APPLE_W_EXTERN"
  fetch_verified_file apple-shell-cmds "$SHELL_CMDS_VERSION-pr_time.c" \
    "https://raw.githubusercontent.com/apple-oss-distributions/shell_cmds/$SHELL_CMDS_VERSION/w/pr_time.c" \
    "$APPLE_W_PR_TIME_SHA256" "$APPLE_W_PR_TIME"
  fetch_verified_file apple-shell-cmds "$SHELL_CMDS_VERSION-proc_compare.c" \
    "https://raw.githubusercontent.com/apple-oss-distributions/shell_cmds/$SHELL_CMDS_VERSION/w/proc_compare.c" \
    "$APPLE_W_PROC_COMPARE_SHA256" "$APPLE_W_PROC_COMPARE"
  fetch_verified_tarball libxo "$LIBXO_VERSION" \
    "https://github.com/Juniper/libxo/archive/refs/tags/$LIBXO_VERSION.tar.gz" \
    "$LIBXO_SHA256" "$LIBXO_TARBALL"
  fetch_verified_file apple-libutil "$APPLE_LIBUTIL_VERSION-libutil.h" \
    "https://raw.githubusercontent.com/apple-oss-distributions/libutil/$APPLE_LIBUTIL_VERSION/libutil.h" \
    "$APPLE_LIBUTIL_H_SHA256" "$APPLE_LIBUTIL_H"
}

write_libxo_config() {  # dir
  cat > "$1/xo_config.h" <<EOF
#ifndef XO_CONFIG_H
#define XO_CONFIG_H
#define LIBXO_VERSION "$LIBXO_VERSION"
#define LIBXO_VERSION_EXTRA ""
#define XO_ENCODERDIR ""
#define HAVE_SYS_TYPES_H 1
#define HAVE_STDARG_H 1
#define HAVE_STDINT_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRING_H 1
#define HAVE_STRINGS_H 1
#define HAVE_UNISTD_H 1
#define HAVE_WCHAR_H 1
#define HAVE_WCTYPE_H 1
#define HAVE_GETOPT_H 1
#define HAVE_ERRNO_H 1
#define HAVE_CTYPE_H 1
#define HAVE_LIMITS_H 1
#define HAVE_LOCALE_H 1
#define HAVE_LANGINFO_H 1
#define HAVE_MEMRCHR 0
#define HAVE_STRCHRNUL 0
#define HAVE___FLBF 0
#define HAVE_ETEXT 0
#endif
EOF
}

build_apple_uptime_slice() {  # out plat
  local out="$1"; local plat="$2"
  fetch_apple_w_sources
  curl_platform_vars "$plat"

  local cc d work macsdk libxo_src libxo_inc abi_parent
  cc="$(xcrun -f clang)"
  d="$(dirname "$out")"
  abi_parent="$(microosabi_framework_parent "$plat")" || return 1
  work="$BUILD/apple-shell-cmds/uptime-$plat"
  macsdk="$(xcrun --sdk macosx --show-sdk-path)"
  rm -rf "$work"; mkdir -p "$work"
  tar xzf "$LIBXO_TARBALL" -C "$work"
  libxo_src="$work/libxo-$LIBXO_VERSION/libxo"
  libxo_inc="$work/libxo-$LIBXO_VERSION"
  write_libxo_config "$libxo_src"
  cp "$APPLE_W_SOURCE" "$work/w.c"
  cp "$APPLE_W_EXTERN" "$work/extern.h"
  cp "$APPLE_W_PR_TIME" "$work/pr_time.c"
  cp "$APPLE_W_PROC_COMPARE" "$work/proc_compare.c"
  cp "$APPLE_LIBUTIL_H" "$work/libutil.h"

  "$cc" -c $target_flags -I "$INCLUDE" "$CRT/micro_os_crt.c" -o "$d/uptime-crt.o"
  "$cc" -c $target_flags -I "$INCLUDE" "$CRT/micro_os_libc_shim.c" -o "$d/uptime-libc.o"
  "$cc" -c $target_flags -I "$INCLUDE" "$CRT/micro_os_uptime_shim.c" -o "$d/uptime-shim.o"
  "$cc" -c -Os -ffunction-sections -fdata-sections $target_flags \
    -I "$INCLUDE" -I "$work" -I "$libxo_inc" -idirafter "$macsdk/usr/include" \
    -Dmain=entry -DHAVE_KVM=0 -Drealhostname_sa=micro_os_realhostname_sa -include micro_os_crt.h \
    "$work/w.c" -o "$d/uptime-main.o"
  "$cc" -c -Os -ffunction-sections -fdata-sections $target_flags \
    -I "$INCLUDE" -I "$work" -I "$libxo_inc" -idirafter "$macsdk/usr/include" \
    -DHAVE_KVM=0 -include micro_os_crt.h \
    "$work/pr_time.c" -o "$d/uptime-pr-time.o"
  "$cc" -c -Os -ffunction-sections -fdata-sections $target_flags \
    -I "$INCLUDE" -I "$work" -I "$libxo_inc" -idirafter "$macsdk/usr/include" \
    -DHAVE_KVM=0 -include micro_os_crt.h \
    "$work/proc_compare.c" -o "$d/uptime-proc-compare.o"
  "$cc" -c -Os -ffunction-sections -fdata-sections $target_flags \
    -DLIBXO_TEXT_ONLY=1 -I "$INCLUDE" -I "$libxo_src" -include micro_os_crt.h \
    "$libxo_src/libxo.c" -o "$d/uptime-libxo.o"
  "$cc" -c -Os -ffunction-sections -fdata-sections $target_flags \
    -DLIBXO_TEXT_ONLY=1 -I "$INCLUDE" -I "$libxo_src" -include micro_os_crt.h \
    "$libxo_src/xo_encoder.c" -o "$d/uptime-xo-encoder.o"
  "$cc" -dynamiclib -Wl,-dead_strip $target_flags \
    "$d/uptime-main.o" "$d/uptime-pr-time.o" "$d/uptime-proc-compare.o" \
    "$d/uptime-libxo.o" "$d/uptime-xo-encoder.o" \
    "$d/uptime-crt.o" "$d/uptime-libc.o" "$d/uptime-shim.o" \
    -F "$abi_parent" -framework MicroOSABI -lsbuf -lresolv -o "$out"
  validate_unexpected_undefineds "$out" uptime "$plat"
}

build_apple_uptime_xcframework() {
  fetch_apple_w_sources || return 1
  fws=()
  for plat in $PLATFORMS; do
    mkdir -p "$BUILD/$plat"
    slice="$BUILD/$plat/uptime.dylib"
    echo "  building uptime slice: $plat"
    build_apple_uptime_slice "$slice" "$plat" || return 1
    fw="$BUILD/$plat/uptime.framework"
    make_framework "$slice" "$fw" "uptime" "$plat"
    fws+=(-framework "$fw")
  done
  rm -rf "$OUT/uptime.xcframework"
  xcrun xcodebuild -create-xcframework "${fws[@]}" -output "$OUT/uptime.xcframework" >/dev/null
  echo "built uptime -> payload/uptime.xcframework ($PLATFORMS) [official Apple shell_cmds $SHELL_CMDS_VERSION w.c, framework]"
}

# ---- ps/pkill: official Apple adv_cmds, built without source patches ----
ADV_CMDS_VERSION="${ADV_CMDS_VERSION:-adv_cmds-237}"
APPLE_PS_C_SHA256="${APPLE_PS_C_SHA256:-d338ad022a81a53a3f34149778b0a3dbe3e31b154395589c333c080ad308ea5a}"
APPLE_PS_H_SHA256="${APPLE_PS_H_SHA256:-3d8fd34c753f2ba15271fd68dd9f7ccb75c33fd3c3e5fbfcbad39e36fa809dea}"
APPLE_PS_EXTERN_H_SHA256="${APPLE_PS_EXTERN_H_SHA256:-d0d16190c082405dbc3f290dce644d00fbd30f6c1c8a6994e57ccd3fcf45a8f8}"
APPLE_PS_FMT_C_SHA256="${APPLE_PS_FMT_C_SHA256:-ea41470d63d9e4d67baedd4f33fa175571636bcdf41b32f7fa1f17dccbc7b705}"
APPLE_PS_KEYWORD_C_SHA256="${APPLE_PS_KEYWORD_C_SHA256:-0af8cc559f9e7e830e5568eb61769df806be8b80a22f3745beeab6431ffa6444}"
APPLE_PS_NLIST_C_SHA256="${APPLE_PS_NLIST_C_SHA256:-57b106ae485b2dd181fc07ead8dcfeb6f4b755733a84fba40440732bc868a11b}"
APPLE_PS_PRINT_C_SHA256="${APPLE_PS_PRINT_C_SHA256:-9f3b9e89bd6e58b9db68919189e34136cb903ed60dd6f06650d77e50a47aa40f}"
APPLE_PS_TASKS_C_SHA256="${APPLE_PS_TASKS_C_SHA256:-56d7b23faa1f6387fa7f53561d4ecd7011ada80af9f39346d58d803b84e9432d}"
APPLE_PKILL_C_SHA256="${APPLE_PKILL_C_SHA256:-19b5c405181a1e27309aa54527103a5ec1e7391b6c865c24dc84817579be5b98}"

fetch_adv_cmds_sources() {
  local base="https://raw.githubusercontent.com/apple-oss-distributions/adv_cmds/$ADV_CMDS_VERSION"
  ADV_CMDS_DIR="$BUILD/apple-adv-cmds/$ADV_CMDS_VERSION"
  mkdir -p "$ADV_CMDS_DIR"
  fetch_verified_file apple-adv-cmds "$ADV_CMDS_VERSION-ps.c" \
    "$base/ps/ps.c" "$APPLE_PS_C_SHA256" "$ADV_CMDS_DIR/ps.c"
  fetch_verified_file apple-adv-cmds "$ADV_CMDS_VERSION-ps.h" \
    "$base/ps/ps.h" "$APPLE_PS_H_SHA256" "$ADV_CMDS_DIR/ps.h"
  fetch_verified_file apple-adv-cmds "$ADV_CMDS_VERSION-extern.h" \
    "$base/ps/extern.h" "$APPLE_PS_EXTERN_H_SHA256" "$ADV_CMDS_DIR/extern.h"
  fetch_verified_file apple-adv-cmds "$ADV_CMDS_VERSION-fmt.c" \
    "$base/ps/fmt.c" "$APPLE_PS_FMT_C_SHA256" "$ADV_CMDS_DIR/fmt.c"
  fetch_verified_file apple-adv-cmds "$ADV_CMDS_VERSION-keyword.c" \
    "$base/ps/keyword.c" "$APPLE_PS_KEYWORD_C_SHA256" "$ADV_CMDS_DIR/keyword.c"
  fetch_verified_file apple-adv-cmds "$ADV_CMDS_VERSION-nlist.c" \
    "$base/ps/nlist.c" "$APPLE_PS_NLIST_C_SHA256" "$ADV_CMDS_DIR/nlist.c"
  fetch_verified_file apple-adv-cmds "$ADV_CMDS_VERSION-print.c" \
    "$base/ps/print.c" "$APPLE_PS_PRINT_C_SHA256" "$ADV_CMDS_DIR/print.c"
  fetch_verified_file apple-adv-cmds "$ADV_CMDS_VERSION-tasks.c" \
    "$base/ps/tasks.c" "$APPLE_PS_TASKS_C_SHA256" "$ADV_CMDS_DIR/tasks.c"
  fetch_verified_file apple-adv-cmds "$ADV_CMDS_VERSION-pkill.c" \
    "$base/pkill/pkill.c" "$APPLE_PKILL_C_SHA256" "$ADV_CMDS_DIR/pkill.c"
}

build_apple_ps_slice() {  # out plat
  local out="$1"; local plat="$2"
  fetch_adv_cmds_sources
  curl_platform_vars "$plat"

  local cc d macsdk compat flags objects file obj abi_parent
  cc="$(xcrun -f clang)"
  d="$(dirname "$out")"
  abi_parent="$(microosabi_framework_parent "$plat")" || return 1
  macsdk="$(xcrun --sdk macosx --show-sdk-path)"
  compat="$BUILD/apple-adv-cmds/compat-$plat"
  rm -rf "$compat"; mkdir -p "$compat/mach"
  cp "$macsdk/usr/include/mach/mach_vm.h" "$compat/mach/mach_vm.h"

  "$cc" -c $target_flags -I "$INCLUDE" "$CRT/micro_os_crt.c" -o "$d/ps-crt.o"
  "$cc" -c $target_flags -I "$INCLUDE" "$CRT/micro_os_libc_shim.c" -o "$d/ps-libc.o"

  flags=(-Os -ffunction-sections -fdata-sections -fblocks $target_flags
    -Dmain=entry -DKERN_PROC_RGID=KERN_PROC_ALL -DKERN_PROC_INC_THREAD=0
    -Wno-deprecated-non-prototype -Wno-incompatible-pointer-types-discards-qualifiers
    -I "$INCLUDE" -I "$ADV_CMDS_DIR" -I "$compat" -idirafter "$macsdk/usr/include"
    -F"$macsdk/System/Library/Frameworks" -iframework "$macsdk/System/Library/Frameworks"
    -include micro_os_crt.h)
  objects=("$d/ps-crt.o" "$d/ps-libc.o")
  for file in ps.c fmt.c keyword.c nlist.c print.c tasks.c; do
    obj="$d/ps-${file%.c}.o"
    "$cc" -c "${flags[@]}" "$ADV_CMDS_DIR/$file" -o "$obj"
    objects+=("$obj")
  done
  "$cc" -dynamiclib -Wl,-dead_strip $target_flags \
    "${objects[@]}" -F "$abi_parent" -framework MicroOSABI -o "$out"
  validate_unexpected_undefineds "$out" ps "$plat"
}

build_apple_ps_xcframework() {
  fetch_adv_cmds_sources || return 1
  fws=()
  for plat in $PLATFORMS; do
    mkdir -p "$BUILD/$plat"
    slice="$BUILD/$plat/ps.dylib"
    echo "  building ps slice: $plat"
    build_apple_ps_slice "$slice" "$plat" || return 1
    fw="$BUILD/$plat/ps.framework"
    make_framework "$slice" "$fw" "ps" "$plat"
    fws+=(-framework "$fw")
  done
  rm -rf "$OUT/ps.xcframework"
  xcrun xcodebuild -create-xcframework "${fws[@]}" -output "$OUT/ps.xcframework" >/dev/null
  echo "built ps -> payload/ps.xcframework ($PLATFORMS) [official Apple adv_cmds $ADV_CMDS_VERSION, framework]"
}

build_apple_pkill_slice() {  # out plat
  local out="$1"; local plat="$2"
  fetch_adv_cmds_sources
  curl_platform_vars "$plat"

  local cc d macsdk abi_parent
  cc="$(xcrun -f clang)"
  d="$(dirname "$out")"
  abi_parent="$(microosabi_framework_parent "$plat")" || return 1
  macsdk="$(xcrun --sdk macosx --show-sdk-path)"

  "$cc" -c $target_flags -I "$INCLUDE" "$CRT/micro_os_crt.c" -o "$d/pkill-crt.o"
  "$cc" -c $target_flags -I "$INCLUDE" "$CRT/micro_os_libc_shim.c" -o "$d/pkill-libc.o"
  "$cc" -c $target_flags -fblocks -I "$INCLUDE" "$CRT/micro_os_sysmon_shim.c" -o "$d/pkill-sysmon.o"
  "$cc" -c -Os -ffunction-sections -fdata-sections -fblocks $target_flags \
    -Dmain=entry -Wno-deprecated-non-prototype \
    -I "$INCLUDE" -I "$ADV_CMDS_DIR" -idirafter "$macsdk/usr/include" \
    -include micro_os_crt.h \
    "$ADV_CMDS_DIR/pkill.c" -o "$d/pkill-main.o"
  "$cc" -dynamiclib -Wl,-dead_strip $target_flags \
    "$d/pkill-main.o" "$d/pkill-sysmon.o" "$d/pkill-crt.o" "$d/pkill-libc.o" \
    -F "$abi_parent" -framework MicroOSABI -o "$out"
  validate_unexpected_undefineds "$out" pkill "$plat"
}

build_apple_pkill_xcframework() {
  fetch_adv_cmds_sources || return 1
  fws=()
  for plat in $PLATFORMS; do
    mkdir -p "$BUILD/$plat"
    slice="$BUILD/$plat/pkill.dylib"
    echo "  building pkill slice: $plat"
    build_apple_pkill_slice "$slice" "$plat" || return 1
    fw="$BUILD/$plat/pkill.framework"
    make_framework "$slice" "$fw" "pkill" "$plat"
    fws+=(-framework "$fw")
  done
  rm -rf "$OUT/pkill.xcframework"
  xcrun xcodebuild -create-xcframework "${fws[@]}" -output "$OUT/pkill.xcframework" >/dev/null
  echo "built pkill -> payload/pkill.xcframework ($PLATFORMS) [official Apple adv_cmds $ADV_CMDS_VERSION, framework]"
}

# ---- fastfetch: official upstream CMake project, built without source patches ----
FASTFETCH_VERSION="${FASTFETCH_VERSION:-2.52.0}"
FASTFETCH_SHA256="${FASTFETCH_SHA256:-6199c4cacc0b411fde7ec6c66d12829459284c6cdfb4bacce7b535190d5cd94c}"

fetch_fastfetch_sources() {
  FASTFETCH_TARBALL="$BUILD/fastfetch/fastfetch-$FASTFETCH_VERSION.tar.gz"
  fetch_verified_tarball fastfetch "$FASTFETCH_VERSION" \
    "https://github.com/fastfetch-cli/fastfetch/archive/refs/tags/$FASTFETCH_VERSION.tar.gz" \
    "$FASTFETCH_SHA256" "$FASTFETCH_TARBALL"
}

prepare_fastfetch_microos_sources() {  # src
  local src="$1"
  local apple_src dir base module nosupport

  while IFS= read -r apple_src; do
    case "$apple_src" in
      src/detection/swap/*) continue ;;
    esac
    dir="${apple_src%/*}"
    base="${apple_src##*/}"
    module="${base%_apple.*}"
    nosupport="$dir/${module}_nosupport.c"
    if [ -f "$src/$nosupport" ]; then
      APPLE_SRC="$apple_src" NOSUPPORT_SRC="$nosupport" \
        perl -0pi -e 's#\Q$ENV{APPLE_SRC}\E#$ENV{NOSUPPORT_SRC}#g' "$src/CMakeLists.txt"
    fi
  done < <(grep -oE 'src/detection/[^[:space:]]+_apple\.[cm]' "$src/CMakeLists.txt" | sort -u)

  # The iOS SDK exposes the route socket headers only partially; do not fake
  # /proc-/netlink-style data. Report "no default route info" through a tiny
  # microOS shim while keeping upstream fastfetch sources unmodified.
  FASTFETCH_NETIF_SHIM="$_SAFE/crt/fastfetch_microos_netif.c" \
    perl -0pi -e 's#src/common/netif/netif_apple\.c#$ENV{FASTFETCH_NETIF_SHIM}#g' "$src/CMakeLists.txt"
  FASTFETCH_DISPLAYSERVER_SHIM="$_SAFE/crt/fastfetch_microos_displayserver.c" \
    perl -0pi -e 's#src/detection/displayserver/displayserver_apple\.c#$ENV{FASTFETCH_DISPLAYSERVER_SHIM}#g' "$src/CMakeLists.txt"
  FASTFETCH_OPENGL_SHIM="$_SAFE/crt/fastfetch_microos_opengl.c" \
    perl -0pi -e 's#src/detection/opengl/opengl_apple\.c#$ENV{FASTFETCH_OPENGL_SHIM}#g' "$src/CMakeLists.txt"
  FASTFETCH_OPENCL_SHIM="$_SAFE/crt/fastfetch_microos_opencl.c" \
    perl -0pi -e 's#src/detection/opencl/opencl\.c#$ENV{FASTFETCH_OPENCL_SHIM}#g' "$src/CMakeLists.txt"
  FASTFETCH_KMOD_SHIM="$_SAFE/crt/fastfetch_microos_kmod.c" \
    perl -0pi -e 's#src/util/kmod\.c#$ENV{FASTFETCH_KMOD_SHIM}#g' "$src/CMakeLists.txt"
  FASTFETCH_OSASCRIPT_SHIM="$_SAFE/crt/fastfetch_microos_osascript.c" \
    perl -0pi -e 's#^\s*src/util/apple/osascript\.m\s*$#$ENV{FASTFETCH_OSASCRIPT_SHIM}#mg' "$src/CMakeLists.txt"
  perl -0pi -e 's#src/detection/dns/dns_apple\.c#src/detection/dns/dns_linux.c#g' "$src/CMakeLists.txt"
  perl -0pi -e 's#src/detection/users/users_linux\.c#src/detection/users/users_nosupport.c#g' "$src/CMakeLists.txt"
  perl -0pi -e 's#^\s*src/util/apple/smc_temps\.c\s*$##mg' "$src/CMakeLists.txt"
}

build_fastfetch_slice() {  # out plat
  local out="$1"; local plat="$2"
  fetch_fastfetch_sources
  curl_platform_vars "$plat"

  local cc d src bld macsdk fastfetch_cflags abi_parent
  cc="$(xcrun -f clang)"
  d="$(dirname "$out")"
  abi_parent="$(microosabi_framework_parent "$plat")" || return 1
  src="$BUILD/fastfetch/fastfetch-$plat-src"
  bld="$BUILD/fastfetch/fastfetch-$plat-build"
  macsdk="$(xcrun --sdk macosx --show-sdk-path)"
  fastfetch_cflags="$target_flags -I$INCLUDE -idirafter $macsdk/usr/include -F$macsdk/System/Library/Frameworks -iframework $macsdk/System/Library/Frameworks -include $INCLUDE/micro_os_crt.h"
  rm -rf "$src" "$bld"; mkdir -p "$src" "$bld"
  tar -xzf "$FASTFETCH_TARBALL" -C "$src" --strip-components 1
  prepare_fastfetch_microos_sources "$src"

  "$cc" -c $target_flags -I "$INCLUDE" "$CRT/micro_os_crt.c" -o "$d/fastfetch-crt.o"
  "$cc" -c $target_flags -I "$INCLUDE" "$CRT/micro_os_libc_shim.c" -o "$d/fastfetch-libc.o"

  cmake -S "$src" -B "$bld" -G "Unix Makefiles" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="$sdk" \
    -DCMAKE_OSX_ARCHITECTURES="$arch" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
    -DCMAKE_C_COMPILER="$cc" \
    -DCMAKE_C_FLAGS="$fastfetch_cflags" \
    -DCMAKE_OBJC_COMPILER="$cc" \
    -DCMAKE_OBJC_FLAGS="$fastfetch_cflags" \
    -DCMAKE_EXE_LINKER_FLAGS="$target_flags -dynamiclib -Wl,-alias,_main,_entry $d/fastfetch-crt.o $d/fastfetch-libc.o -F$abi_parent -framework MicroOSABI" \
    -DBINARY_LINK_TYPE=dlopen \
    -DHAVE_WORDEXP=OFF \
    -DHAVE_GLOB=OFF \
    -DENABLE_VULKAN=OFF \
    -DENABLE_EGL=OFF \
    -DENABLE_GLX=OFF \
    -DENABLE_OPENCL=OFF \
    -DBUILD_TESTS=OFF \
    -DBUILD_FLASHFETCH=OFF \
    -DENABLE_SYSTEM_YYJSON=OFF
  cmake --build "$bld" --target libfastfetch --parallel "${MAKE_JOBS:-2}" || return 1

  local flags defs includes
  flags="$(sed -n 's/^C_FLAGS = //p' "$bld/CMakeFiles/libfastfetch.dir/flags.make")"
  defs="$(sed -n 's/^C_DEFINES = //p' "$bld/CMakeFiles/libfastfetch.dir/flags.make")"
  includes="$(sed -n 's/^C_INCLUDES = //p' "$bld/CMakeFiles/libfastfetch.dir/flags.make")"
  eval "set -- $flags $defs $includes"
  "$cc" -c "$@" -DFASTFETCH_TARGET_BINARY_NAME=fastfetch \
    "$src/src/fastfetch.c" -o "$d/fastfetch-main.o"
  find "$bld/CMakeFiles/libfastfetch.dir" -name '*.o' -print > "$d/fastfetch-objs.rsp"
  "$cc" -dynamiclib $target_flags -Wl,-alias,_main,_entry \
    "$d/fastfetch-crt.o" "$d/fastfetch-libc.o" "$d/fastfetch-main.o" \
    @"$d/fastfetch-objs.rsp" -lz -lsqlite3 -lobjc \
    -F "$abi_parent" -framework MicroOSABI \
    -framework Foundation -framework CoreFoundation \
    -o "$out"
}

build_fastfetch_xcframework() {
  fetch_fastfetch_sources || return 1
  fws=()
  for plat in $PLATFORMS; do
    mkdir -p "$BUILD/$plat"
    slice="$BUILD/$plat/fastfetch.dylib"
    echo "  building fastfetch slice: $plat"
    build_fastfetch_slice "$slice" "$plat" || return 1
    fw="$BUILD/$plat/fastfetch.framework"
    make_framework "$slice" "$fw" "fastfetch" "$plat"
    fws+=(-framework "$fw")
  done
  rm -rf "$OUT/fastfetch.xcframework"
  xcrun xcodebuild -create-xcframework "${fws[@]}" -output "$OUT/fastfetch.xcframework" >/dev/null
  echo "built fastfetch -> payload/fastfetch.xcframework ($PLATFORMS) [official fastfetch $FASTFETCH_VERSION, framework]"
}

build_vcocoa() {  # out appsrc
  out="$1"; appsrc="$2"; d="$(dirname "$out")"; rt="$ROOT/runtimes/vcocoa"
  xcrun clang -c "${CLANG_SDK[@]}" -I "$INCLUDE" "$CRT/micro_os_crt.c" -o "$d/crt.o"
  xcrun clang -c "${CLANG_SDK[@]}" -I "$INCLUDE" "$CRT/micro_os_libc_shim.c" -o "$d/libc.o"
  xcrun clang -c "${CLANG_SDK[@]}" -I "$INCLUDE" "$CRT/micro_os_gui_shim.c" -o "$d/gui.o"
  xcrun clang -c -fobjc-arc -DMICRO_OS_APPKIT_SHIM=1 "${CLANG_SDK[@]}" -I "$INCLUDE" -I "$rt/include" \
    "$rt/micro_os_appkit_shim.m" -o "$d/appkit.o"
  xcrun clang -c -fobjc-arc -DMICRO_OS_APPKIT_SHIM=1 "${CLANG_SDK[@]}" -I "$INCLUDE" -I "$rt/include" \
    -Dmain=micro_os_appkit_user_main -include micro_os_crt.h "$appsrc" -o "$d/app.o"
  xcrun swiftc -emit-library -parse-as-library "${SWIFT_SDK[@]}" \
    "$INCLUDE/MicroOS.swift" "$rt/VCocoaRuntime.swift" \
    "$d/app.o" "$d/crt.o" "$d/libc.o" "$d/gui.o" "$d/appkit.o" \
    -module-name "$(basename "$out" .dylib | tr -c "[:alnum:]_" "_")" -Xlinker -undefined -Xlinker dynamic_lookup -o "$out"
}

build_vwin32() {  # out appsrc
  out="$1"; appsrc="$2"; d="$(dirname "$out")"; rt="$ROOT/runtimes/vwin32"
  xcrun clang -c "${CLANG_SDK[@]}" -I "$INCLUDE" "$CRT/micro_os_crt.c" -o "$d/crt.o"
  xcrun clang -c "${CLANG_SDK[@]}" -I "$INCLUDE" "$CRT/micro_os_libc_shim.c" -o "$d/libc.o"
  xcrun clang -c "${CLANG_SDK[@]}" -I "$INCLUDE" "$CRT/micro_os_gui_shim.c" -o "$d/gui.o"
  xcrun clang -c -DMICRO_OS_WIN32_SHIM=1 "${CLANG_SDK[@]}" -I "$INCLUDE" -I "$rt/include" \
    "$rt/micro_os_win32_shim.c" -o "$d/win32.o"
  xcrun clang -c -DMICRO_OS_WIN32_SHIM=1 "${CLANG_SDK[@]}" -I "$INCLUDE" -I "$rt/include" \
    -DWinMain=micro_os_win32_user_main -include micro_os_crt.h "$appsrc" -o "$d/app.o"
  xcrun swiftc -emit-library -parse-as-library "${SWIFT_SDK[@]}" \
    "$INCLUDE/MicroOS.swift" "$rt/VWin32Runtime.swift" \
    "$d/app.o" "$d/crt.o" "$d/libc.o" "$d/gui.o" "$d/win32.o" \
    -module-name "$(basename "$out" .dylib | tr -c "[:alnum:]_" "_")" -Xlinker -undefined -Xlinker dynamic_lookup -o "$out"
}

# Seed a default init.conf into payload/etc when one doesn't exist yet.
# NEVER clobbers an existing config — your local payload/etc/init.conf is left
# untouched. The default drops into the toybox shell, so a fresh payload runs
# out of the box (build toybox: it's in the default system group).
seed_default_init_conf() {
  conf="$OUT/etc/init.conf"
  if [ -f "$conf" ]; then
    echo "init.conf present -> keeping payload/etc/init.conf (not overwritten)"
    return
  fi
  mkdir -p "$OUT/etc"
  cat > "$conf" <<'EOF'
# init configuration (TOML). init reads this from $BUNDLE/etc/init.conf.
#
# Two commands:
#   pre-start : bootstrap, run to completion before start.
#   start     : the session. When it exits, the system halts (kernel panic).
#
# Single-quoted TOML literals keep shell quoting intact (init unescapes \" so
# the inner quotes survive — needed because $HOME lives under "Application
# Support", which contains a space). The loader exports $HOME, $BUNDLE
# (= BundledDylibs), $BIN (= $HOME/.local/bin) and $PATH (includes $BIN);
# init adds $APP_ROOT (= the bundle dir).

[command]
# Install $BIN command links for the toybox applets (so the shell finds ls, cat,
# … in $PATH) by sourcing the build-generated script, which uses toybox's own ln.
# The link target's missing +x (read-only bundle) is covered by the kernel's
# access(); commands run as real child processes via the fork()-via-spawn path.
pre-start = 'toybox sh -c ". $BUNDLE/etc/setup-path"'

# Drop into the interactive toybox shell.
start = 'toybox sh -i'
EOF
  echo "seeded default toybox config -> payload/etc/init.conf"
}

# Wrap a built dylib slice into a minimal .framework bundle. App Store rejects
# bare dylibs in the app (ITMS-90171); loadable code must be a proper bundle, so
# every program ships as Frameworks/<name>.framework/<name>. Sets the framework
# binary's id to @rpath/<name>.framework/<name> and writes a FMWK Info.plist with
# the right platform so `xcodebuild -create-xcframework -framework` accepts it.
make_framework() {  # dylib fwdir name plat
  _dy="$1"; _fw="$2"; _fn="$3"; _plat="$4"
  validate_unexpected_undefineds "$_dy" "$_fn" "$_plat"
  case "$_plat" in
    iphoneos)        _splat="iPhoneOS" ;;
    iphonesimulator) _splat="iPhoneSimulator" ;;
    *)               _splat="iPhoneOS" ;;
  esac
  rm -rf "$_fw"; mkdir -p "$_fw"
  cp "$_dy" "$_fw/$_fn"
  if [ -d "$(dirname "$_dy")/$_fn.resources" ]; then
    cp -R "$(dirname "$_dy")/$_fn.resources"/. "$_fw"/
  fi
  xcrun install_name_tool -id "@rpath/$_fn.framework/$_fn" "$_fw/$_fn" 2>/dev/null
  cat > "$_fw/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleExecutable</key><string>$_fn</string>
	<key>CFBundleIdentifier</key><string>jp.takpika.micro-os.prog.$_fn</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>$_fn</string>
	<key>CFBundlePackageType</key><string>FMWK</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>MinimumOSVersion</key><string>15.0</string>
	<key>CFBundleSupportedPlatforms</key><array><string>$_splat</string></array>
</dict>
</plist>
EOF
}

# ---- build every platform slice, wrap as a .framework, pack into an .xcframework ----
build_xcf() {  # name buildfn args...
  name="$1"; buildfn="$2"; shift 2
  fws=()
  for plat in $PLATFORMS; do
    set_platform "$plat"
    mkdir -p "$BUILD/$plat"
    slice="$BUILD/$plat/$name.dylib"
    "$buildfn" "$slice" "$@"
    fw="$BUILD/$plat/$name.framework"
    make_framework "$slice" "$fw" "$name" "$plat"
    fws+=(-framework "$fw")
  done
  rm -rf "$OUT/$name.xcframework"
  xcrun xcodebuild -create-xcframework "${fws[@]}" -output "$OUT/$name.xcframework" >/dev/null
  echo "built $name -> payload/$name.xcframework ($PLATFORMS) [framework]"
}

build_one() {
  case "$1" in
    init)                  build_xcf init build_c "$ROOT/apps/init/init.c"; seed_default_init_conf ;;
    # The host ABI as a dylib (not a program/command). Programs resolve micro_os_*
    # against this framework, which the app loads globally at boot. On device dyld
    # won't resolve those flat-namespace symbols against the main executable, only
	    # against loaded dylibs — so the ABI must live in one.
    MicroOSABI)            build_xcf MicroOSABI build_microosabi "$CRT/micro_os_abi.c" ;;
	    wm)                    build_wm_xcframework ;;
    toybox)                build_toybox_xcframework ;;
    gzip|more)             build_toybox_xcframework ;;
    curl)                  build_curl_xcframework ;;
    ifconfig)              build_ifconfig_xcframework ;;
    ping)                  build_ping_xcframework ;;
    zip)                   build_infozip_xcframework zip build_zip_slice ;;
    unzip)                 build_infozip_xcframework unzip build_unzip_slice ;;
    zlib)                  build_zlib_xcframework ;;
    xz)                    build_xz_xcframework ;;
    bzip2)                 build_bzip2_xcframework ;;
    less)                  build_less_xcframework ;;
    awk)                   build_awk_xcframework ;;
    traceroute)            build_traceroute_xcframework ;;
    whois)                 build_whois_xcframework ;;
    uptime)                build_apple_uptime_xcframework ;;
    ps)                    build_apple_ps_xcframework ;;
    pkill)                 build_apple_pkill_xcframework ;;
    fastfetch)             build_fastfetch_xcframework ;;
    bind-dns-tools|dig|nslookup)
                            build_bind_dns_tools_xcframework ;;
    demo-program)          build_xcf demo-program build_c_crt "$ROOT/samples/demo-program.c" ;;
    file-fallback-program) build_xcf file-fallback-program build_c_crt "$ROOT/samples/file-fallback-program.c" ;;
    stdin-program)         build_xcf stdin-program build_c_crt "$ROOT/samples/stdin-program.c" ;;
    SwiftOverlayProgram)   build_xcf SwiftOverlayProgram build_swift "$ROOT/samples/SwiftOverlayProgram.swift" "$INCLUDE/MicroOS.swift" ;;
    TerminalProgram)       build_xcf TerminalProgram build_swift "$ROOT/samples/TerminalProgram.swift" "$ROOT/micro-os/kernel/KeyboardEvent.swift" "$ROOT/micro-os/ui/MicroOSKeyboardAccessoryBar.swift" "$INCLUDE/MicroOS.swift" ;;
    vcocoa-todo)           build_xcf vcocoa-todo build_vcocoa "$ROOT/samples/vcocoa-todo.m" ;;
    vwin32-todo)           build_xcf vwin32-todo build_vwin32 "$ROOT/samples/vwin32-todo.c" ;;
    *)
      # Fall back to a local (untracked) recipe: a build_<name> function defined
      # by a drop-in under scripts/local/ (see below). Keeps private programs out
      # of the repo while still building through the same pipeline.
      if declare -F "build_$1" >/dev/null 2>&1; then
        build_xcf "$1" "build_$1"
      else
        echo "unknown program: $1" >&2; return 1
      fi
      ;;
  esac
}

# Local program recipes — untracked drop-ins (scripts/local/ is gitignored).
# Each *.sh may define build_<name>() and append its name to LOCAL_PROGRAMS so it
# joins the "all"/"local" groups. This is the supported way to build programs that
# must not be committed to the repo.
LOCAL_PROGRAMS=""
for f in "$ROOT"/scripts/local/*.sh; do
  [ -f "$f" ] && . "$f"
done

# Program groups. The build-system.sh / build-samples.sh entry points just set
# GROUP and delegate here; this script can also be run directly (GROUP=all).
SYSTEM_PROGRAMS="MicroOSABI init wm toybox"
SAMPLE_PROGRAMS="demo-program file-fallback-program stdin-program SwiftOverlayProgram TerminalProgram vcocoa-todo vwin32-todo"
OPTIONAL_PROGRAMS="curl ifconfig ping bind-dns-tools zip unzip zlib xz bzip2 less awk traceroute whois uptime ps pkill fastfetch"
case "${GROUP:-all}" in
  system)  GROUP_PROGRAMS="$SYSTEM_PROGRAMS" ;;
  samples) GROUP_PROGRAMS="$SAMPLE_PROGRAMS" ;;
  optional) GROUP_PROGRAMS="$OPTIONAL_PROGRAMS" ;;
  local)   GROUP_PROGRAMS="$LOCAL_PROGRAMS" ;;
  all)     GROUP_PROGRAMS="$SYSTEM_PROGRAMS $SAMPLE_PROGRAMS $LOCAL_PROGRAMS" ;;
  *) echo "unknown GROUP: $GROUP (use system | samples | optional | local | all)" >&2; exit 1 ;;
esac

if [ "${1:-}" = "--list" ]; then printf '%s\n' $GROUP_PROGRAMS; exit 0; fi
if [ "${1:-}" = "--add-distribution-privacy-manifests" ]; then
  add_distribution_privacy_manifests; exit $?
fi
# Regenerate payload/etc/setup-path from the already-built toybox slice, without
# rebuilding toybox. Useful after changing the provisioning template.
if [ "${1:-}" = "--write-setup-path" ]; then
  write_setup_path "$BUILD/${PLATFORMS%% *}/toybox.dylib"; exit $?
fi
selection="$*"; [ -z "$selection" ] && selection="$GROUP_PROGRAMS"
for program in $selection; do build_one "$program"; done
