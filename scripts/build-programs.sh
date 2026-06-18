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
#
# Platforms (default both). Faster sim-only build:
#   PLATFORMS=iphonesimulator scripts/build-programs.sh init
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/payload"
BUILD="$ROOT/.build/programs"
INCLUDE="$ROOT/include"
CRT="$ROOT/crt"
mkdir -p "$OUT" "$BUILD"

PLATFORMS="${PLATFORMS:-iphoneos iphonesimulator}"
CLANG_SDK=()
SWIFT_SDK=()

set_platform() {
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

# ---- per-slice build helpers (emit ONE dylib for the current platform) ----

build_swift() {  # out source...
  out="$1"; shift
  xcrun swiftc -emit-library -parse-as-library "${SWIFT_SDK[@]}" "$@" \
    -module-name "$(basename "$out" .dylib | tr -c "[:alnum:]_" "_")" -Xlinker -undefined -Xlinker dynamic_lookup -o "$out"
}

build_c() {  # out source...  (plain C, no CRT shim; uses the host ABI directly)
  out="$1"; shift
  xcrun clang -dynamiclib -undefined dynamic_lookup "${CLANG_SDK[@]}" -I "$INCLUDE" "$@" -o "$out"
}

build_c_crt() {  # out source...
  out="$1"; shift; d="$(dirname "$out")"
  xcrun clang -c "${CLANG_SDK[@]}" -I "$INCLUDE" "$CRT/micro_os_crt.c" -o "$d/crt.o"
  xcrun clang -c "${CLANG_SDK[@]}" -I "$INCLUDE" "$CRT/micro_os_libc_shim.c" -o "$d/libc.o"
  xcrun clang -dynamiclib -undefined dynamic_lookup "${CLANG_SDK[@]}" -I "$INCLUDE" \
    -include micro_os_crt.h "$@" "$d/crt.o" "$d/libc.o" -o "$out"
}

# wm is a real Xcode target (it depends on the SwiftUIWindow SPM package). Build
# it per platform with xcodebuild, then pack the slices into an xcframework.
# This is independent of the app target, so the app stays a pure kernel.
build_wm_xcframework() {
  fws=()
  for plat in $PLATFORMS; do
    dir="$BUILD/wm-$plat"
    rm -rf "$dir"; mkdir -p "$dir"
    xcrun xcodebuild -project "$ROOT/micro-os.xcodeproj" -target wm \
      -sdk "$plat" -configuration Release \
      CODE_SIGNING_ALLOWED=NO \
      CONFIGURATION_BUILD_DIR="$dir" \
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
    # linux32 needs personality() — a Linux syscall absent on Apple platforms
    # (macOS too). The auto-prune can't catch it: -undefined dynamic_lookup lets
    # it link, and the iOS SDK .tbd declares it, so it only fails at runtime
    # dlopen. Disable it explicitly.
    sed -i '' 's/^CONFIG_LINUX32=y$/# CONFIG_LINUX32 is not set/' .config
    cflags="$tgt -Dmain=entry -include $work/inc/micro_os_crt.h -I $work/inc -ferror-limit=0"
    # iconv (iconv/iconv_open) and host (res_9_*) live in libiconv/libresolv —
    # present on iOS but not auto-loaded, so link them or those commands fail at
    # dlopen. They are NOT Linux-only (they work on macOS too).
    ldflags="-dynamiclib -undefined dynamic_lookup -liconv -lresolv $work/crt.o $work/libc.o"
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
      NOSTRIP=1 make CC="$cc" HOSTCC=clang CFLAGS="$cflags" LDFLAGS="$ldflags" >"$work/round.log" 2>&1 && { built=1; break; }
      prune_log "$work/round.log"
      if [ -z "$ch" ]; then
        # toybox builds in parallel; interleaved output can mangle the file name
        # on an error line. Rebuild serially (CPUS=1) for a clean log, then map.
        rm -f generated/zhelp.h
        NOSTRIP=1 CPUS=1 make CC="$cc" HOSTCC=clang CFLAGS="$cflags" LDFLAGS="$ldflags" >"$work/round.log" 2>&1 && { built=1; break; }
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
  applets="$(nm -gU "$slice" 2>/dev/null | grep -oE '_[a-z0-9_]+_main$' | sed 's/^_//; s/_main$//' | sort -u | tr '\n' ' ')"
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
    echo '   case "$n" in toybox|init|MicroOSABI) ;; *) "$T" ln -sf "$d/$n" "$BIN/$n";; esac'
    echo 'done'
    echo '# Bundled app data -> the working-dir-relative ./data an app expects'
    echo '# (an app that reads ./data from its CWD finds it at $HOME/data).'
    echo '[ -e "$BUNDLE/data" ] && "$T" ln -sf "$BUNDLE/data" "$HOME/data"'
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

fetch_verified_tarball() {  # name version url sha out
  local name="$1"; local version="$2"; local url="$3"; local want="$4"; local out="$5"
  mkdir -p "$(dirname "$out")"
  if [ ! -f "$out" ]; then
    echo "  fetching $url"
    curl -fsSL -o "$out" "$url"
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
      LDFLAGS="$target_flags -dynamiclib -undefined dynamic_lookup -Wl,-alias,_main,_entry $d/curl-crt.o $d/curl-libc.o -L$ossl/lib" \
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
  case "$_plat" in
    iphoneos)        _splat="iPhoneOS" ;;
    iphonesimulator) _splat="iPhoneSimulator" ;;
    *)               _splat="iPhoneOS" ;;
  esac
  rm -rf "$_fw"; mkdir -p "$_fw"
  cp "$_dy" "$_fw/$_fn"
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
    MicroOSABI)            build_xcf MicroOSABI build_c "$CRT/micro_os_abi.c" ;;
    wm)                    build_wm_xcframework ;;
    toybox)                build_toybox_xcframework ;;
    curl)                  build_curl_xcframework ;;
    demo-program)          build_xcf demo-program build_c_crt "$ROOT/samples/demo-program.c" ;;
    file-fallback-program) build_xcf file-fallback-program build_c_crt "$ROOT/samples/file-fallback-program.c" ;;
    stdin-program)         build_xcf stdin-program build_c_crt "$ROOT/samples/stdin-program.c" ;;
    SwiftOverlayProgram)   build_xcf SwiftOverlayProgram build_swift "$ROOT/samples/SwiftOverlayProgram.swift" "$INCLUDE/MicroOS.swift" ;;
    TerminalProgram)       build_xcf TerminalProgram build_swift "$ROOT/samples/TerminalProgram.swift" "$INCLUDE/MicroOS.swift" ;;
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
OPTIONAL_PROGRAMS="curl"
case "${GROUP:-all}" in
  system)  GROUP_PROGRAMS="$SYSTEM_PROGRAMS" ;;
  samples) GROUP_PROGRAMS="$SAMPLE_PROGRAMS" ;;
  optional) GROUP_PROGRAMS="$OPTIONAL_PROGRAMS" ;;
  local)   GROUP_PROGRAMS="$LOCAL_PROGRAMS" ;;
  all)     GROUP_PROGRAMS="$SYSTEM_PROGRAMS $SAMPLE_PROGRAMS $LOCAL_PROGRAMS" ;;
  *) echo "unknown GROUP: $GROUP (use system | samples | optional | local | all)" >&2; exit 1 ;;
esac

if [ "${1:-}" = "--list" ]; then printf '%s\n' $GROUP_PROGRAMS; exit 0; fi
# Regenerate payload/etc/setup-path from the already-built toybox slice, without
# rebuilding toybox. Useful after changing the provisioning template.
if [ "${1:-}" = "--write-setup-path" ]; then
  write_setup_path "$BUILD/${PLATFORMS%% *}/toybox.dylib"; exit $?
fi
selection="$*"; [ -z "$selection" ] && selection="$GROUP_PROGRAMS"
for program in $selection; do build_one "$program"; done
