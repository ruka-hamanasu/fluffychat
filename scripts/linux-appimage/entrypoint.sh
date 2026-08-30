#!/bin/bash
# Entrypoint that runs inside the Holy Build Box (Enterprise Linux 8) AppImage
# build container.
set -e

# Ensure a writable HOME and a persistent pub cache inside the project mount.
export HOME=/tmp/home
export PUB_CACHE=/build/.pub-cache
mkdir -p "$PUB_CACHE"

cd /build

# ---------------------------------------------------------------------------
# Temporary pubspec modifications (restored on exit, also on failure):
#
# Replace desktop_webview_window with the pure-Dart stub in
# scripts/linux-appimage/stub_desktop_webview_window. On Linux the embedded
# webview is never opened (flutter_web_auth_2 is always called with
# useWebview: PlatformInfos.isMobile == false), so the native plugin only
# serves to drag the whole WebKitGTK stack into the AppImage.
#
# Note on the sqlite3 hook: it keeps `source: system` (the prebuilt `sqlite3`
# source would download a library requiring GLIBC_2.34, defeating the point of
# building on Holy Build Box), but `name: sqlcipher` is injected below so Dart
# FFI dlopen()s `libsqlcipher.so` instead of `libsqlite3.so`. That library is
# built from source in the Dockerfile against the EL8 userspace and bundled
# into the AppImage, which is what makes the encrypted database work (plain
# libsqlite3 has no SQLCipher codec and SQfLiteEncryptionHelper refuses to
# silently fall back to an unencrypted database).
# ---------------------------------------------------------------------------
# Files flutter rewrites when resolving dependencies with the temporary
# override below; back them up and restore them on exit (also on failure) so
# the host working tree stays untouched by the container build.
GENERATED_FILES="pubspec.yaml pubspec.lock \
linux/flutter/generated_plugin_registrant.cc \
linux/flutter/generated_plugins.cmake \
macos/Flutter/GeneratedPluginRegistrant.swift \
windows/flutter/generated_plugin_registrant.cc \
windows/flutter/generated_plugins.cmake"
for f in $GENERATED_FILES; do cp "$f" "$f.appimage-backup"; done
restore_files() {
    for f in $GENERATED_FILES; do mv -f "$f.appimage-backup" "$f"; done
}
trap restore_files EXIT

# `dependency_overrides:` is the last (empty) section of pubspec.yaml.
cat >> pubspec.yaml <<'EOF'
  desktop_webview_window:
    # Linux AppImage build only: stub without native code, see comment in
    # scripts/linux-appimage/entrypoint.sh. Not committed to the repo.
    path: scripts/linux-appimage/stub_desktop_webview_window
EOF

# Point the sqlite3 hook at SQLCipher (see the note above). With
# `source: system` the hook dlopen()s `lib<name>.so` at runtime; `name`
# changes that lookup from libsqlite3.so to libsqlcipher.so.
sed -i '/^      source: system$/a\      name: sqlcipher' pubspec.yaml
grep -A1 'source: system' pubspec.yaml | grep -q 'name: sqlcipher' || {
    echo "Error: failed to set sqlite3 hook name to sqlcipher" >&2
    exit 1
}

echo "=== Cleaning previous build ==="
flutter clean

# ---------------------------------------------------------------------------
# Build the libstdc++ ABI shim (consumed by linux/CMakeLists.txt when present).
# We link libstdc++ statically, but EL8's ld (2.30) cannot satisfy versioned
# C++ symbol references coming from prebuilt shared libraries (libwebrtc.so
# needs std::__cxx11::basic_stringstream<char>::ctor @GLIBCXX_3.4.26) from the
# executable, and undefined symbols of shared libraries do not trigger static
# archive extraction. This tiny shared library re-exports the symbol extracted
# from the static libstdc++ archive with a proper version definition. It is
# bundled into the AppImage by linux/CMakeLists.txt.
# ---------------------------------------------------------------------------
echo "=== Building libstdc++ ABI shim ==="
SHIM_DIR=/build/.appimage-build
SHIM_SYM=_ZNSt7__cxx1118basic_stringstreamIcSt11char_traitsIcESaIcEEC1Ev
mkdir -p "$SHIM_DIR"
echo 'void __fluffychat_stdcxx_shim(void) {}' > "$SHIM_DIR/shim.cc"
cat > "$SHIM_DIR/ver.map" <<EOF
GLIBCXX_3.4.26 {
  global: $SHIM_SYM;
  local: *;
};
EOF
clang++ -shared -fPIC "$SHIM_DIR/shim.cc" \
  -static-libstdc++ -static-libgcc \
  -Wl,--undefined="$SHIM_SYM" \
  -Wl,--version-script="$SHIM_DIR/ver.map" \
  -Wl,-soname,libstdcxx_shim.so \
  -o "$SHIM_DIR/libstdcxx_shim.so"
objdump -T "$SHIM_DIR/libstdcxx_shim.so" | grep -q "GLIBCXX_3.4.26 $SHIM_SYM" || {
    echo "Error: ABI shim does not export the required versioned symbol" >&2
    exit 1
}

echo "=== Fetching dependencies ==="
flutter pub get

echo "=== Building Flutter Linux release ==="
flutter build linux --release -v 2>&1 | tee /build/flutter-build.log

# Guard: the WebKitGTK stack must not have crept back into the bundle.
if find build/linux/x64/release/bundle -iname '*webkit*' -o -iname '*webview*' | grep -q .; then
    echo "Error: WebKit/webview artifacts found in the bundle:" >&2
    find build/linux/x64/release/bundle -iname '*webkit*' -o -iname '*webview*' >&2
    exit 1
fi

echo "=== Preparing AppDir ==="
rm -rf AppDir
mkdir -p AppDir/usr/bin AppDir/usr/lib AppDir/usr/share/icons/hicolor/256x256/apps

# The Flutter bundle is relocatable: executable + lib/ + data/ next to each other.
cp -r build/linux/x64/release/bundle/* AppDir/usr/bin/
# AppImage icons must have a standard resolution; render the vector logo at
# 256x256 (assets/logo/img/logo.png is 2000x2000 and gets rejected).
rsvg-convert -w 256 -h 256 assets/logo/vector/logo.svg \
  -o AppDir/usr/share/icons/hicolor/256x256/apps/fluffychat.png

cp scripts/linux-appimage/fluffychat.desktop AppDir/fluffychat.desktop

echo "=== Downloading/extracting AppImage tools ==="
mkdir -p /opt/appimage-tools && cd /opt/appimage-tools

if [ ! -d linuxdeploy ]; then
    wget -q https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage
    chmod +x linuxdeploy-x86_64.AppImage
    ./linuxdeploy-x86_64.AppImage --appimage-extract >/dev/null
    mv squashfs-root linuxdeploy
fi

if [ ! -d appimagetool ]; then
    wget -q https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage
    chmod +x appimagetool-x86_64.AppImage
    ./appimagetool-x86_64.AppImage --appimage-extract >/dev/null
    mv squashfs-root appimagetool
fi

# linuxdeploy discovers plugins as executables named linuxdeploy-plugin-<name>
# on PATH, so download the GTK plugin under exactly that name.
if [ ! -x linuxdeploy-plugin-gtk ]; then
    wget -q -O linuxdeploy-plugin-gtk https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gtk/master/linuxdeploy-plugin-gtk.sh
    chmod +x linuxdeploy-plugin-gtk
fi
export PATH="/opt/appimage-tools:${PATH}"

cd /build

echo "=== Bundling dependencies ==="
# libmpv is dlopen()ed by media_kit at runtime, so linuxdeploy cannot detect
# it as a link-time dependency. RPM Fusion EL8 ships mpv 0.34 (libmpv.so.1),
# which media_kit's loader list (libmpv.so, .so.2, .so.1) accepts.
# libwayland-client.so.0 is on linuxdeploy's excludelist, but libwayland-cursor/
# egl/server ARE bundled (newer EL8 builds); they need the matching client
# library or the app crashes on hosts with an older wayland (symbol lookup
# error: wl_proxy_marshal_flags).
# libsqlcipher.so.0 (built from source in the Dockerfile) provides the
# SQLCipher codec the encrypted database needs; the sqlite3 hook dlopen()s it
# because of the `name: sqlcipher` override above. It links OpenSSL
# dynamically, so EL8's libcrypto.so.1.1 must be bundled too: distros shipping
# OpenSSL 3 (Ubuntu 22.04+ and friends) do not ship libcrypto.so.1.1.
/opt/appimage-tools/linuxdeploy/AppRun \
  --appdir AppDir \
  --plugin gtk \
  --library /usr/lib64/libmpv.so.1 \
  --library /usr/lib64/libsecret-1.so.0 \
  --library /opt/sqlcipher/lib/libsqlcipher.so.0 \
  --library /usr/lib64/libcrypto.so.1.1 \
  --library /usr/lib64/libwayland-client.so.0 \
  --desktop-file AppDir/fluffychat.desktop \
  --icon-file AppDir/usr/share/icons/hicolor/256x256/apps/fluffychat.png

echo "=== Exposing FFI libraries in AppDir/usr/lib ==="
# Dart FFI loads some libraries by bare name via dlopen() (flutter_rust_bridge
# based libvodozemac_bindings_dart.so, hook-based native assets like
# libwebcrypto.so). That search only covers the executable's RUNPATH
# ($ORIGIN/../lib == AppDir/usr/lib) and system paths, NOT the Flutter
# bundle's own usr/bin/lib. Symlink every bundled library into usr/lib so
# these lookups succeed (names already deployed by linuxdeploy are kept).
for lib in AppDir/usr/bin/lib/*.so*; do
    name=$(basename "$lib")
    [ -e "AppDir/usr/lib/$name" ] || ln -s "../bin/lib/$name" "AppDir/usr/lib/$name"
done

# The sqlite3 hook (name: sqlcipher) dlopen()s the unversioned
# `libsqlcipher.so`, but linuxdeploy only ships the versioned soname. Provide
# the unversioned symlink, and fail loudly if the library was not deployed.
test -e AppDir/usr/lib/libsqlcipher.so.0 || {
    echo "Error: libsqlcipher.so.0 was not bundled into AppDir/usr/lib" >&2
    exit 1
}
ln -sf libsqlcipher.so.0 AppDir/usr/lib/libsqlcipher.so

echo "=== Creating AppImage ==="
# Prefer dense squashfs compression (smaller file): zstd if the appimagetool
# runtime supports it, xz otherwise (this appimagetool build has no zstd).
if ! /opt/appimage-tools/appimagetool/AppRun --comp zstd AppDir /output/FluffyChat-x86_64.AppImage; then
    echo "zstd compression unsupported, falling back to xz"
    /opt/appimage-tools/appimagetool/AppRun --comp xz AppDir /output/FluffyChat-x86_64.AppImage
fi

# ---------------------------------------------------------------------------
# Portability audit: report the highest glibc/libstdc++ symbol versions
# required by everything we ship. The build targets glibc <= 2.28
# (Debian 10 / Ubuntu 20.04 / RHEL 8). Prebuilt binaries we do not control
# (Flutter engine, libwebrtc) may raise the floor; warn loudly if they do.
# ---------------------------------------------------------------------------
echo "=== Portability audit ==="
max_glibc=""
max_glibcxx=""
while IFS= read -r -d '' f; do
    vers=$(objdump -T "$f" 2>/dev/null | grep -oE 'GLIBC(X|XX)?_[0-9]+\.[0-9]+(\.[0-9]+)?' || true)
    for v in $vers; do
        case "$v" in
            GLIBCXX_*) [ "$(printf '%s\n%s\n' "$max_glibcxx" "$v" | sort -V | tail -1)" = "$v" ] && max_glibcxx="$v" ;;
            GLIBC_*)   [ "$(printf '%s\n%s\n' "$max_glibc" "$v" | sort -V | tail -1)" = "$v" ] && max_glibc="$v" ;;
        esac
    done
done < <(find AppDir/usr/bin AppDir/usr/lib -type f \( -perm -u+x -o -name '*.so*' \) -print0 2>/dev/null)

echo "Highest required symbols: ${max_glibc:-none} / ${max_glibcxx:-none}"
if [ -n "$max_glibc" ] && [ "$(printf '%s\n%s\n' "$max_glibc" "GLIBC_2.28" | sort -V | tail -1)" != "GLIBC_2.28" ]; then
    echo "WARNING: bundle requires ${max_glibc} > GLIBC_2.28 (likely a prebuilt library such as libwebrtc.so or libflutter_linux_gtk.so); the AppImage will not run on Debian 10 / Ubuntu 20.04." >&2
fi

echo "=== Done ==="
ls -lh /output/FluffyChat-x86_64.AppImage
