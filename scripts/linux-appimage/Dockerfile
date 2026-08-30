# FluffyChat Linux AppImage build environment based on Holy Build Box 4.x.
#
# Holy Build Box (https://github.com/phusion/holy-build-box) is a Rocky Linux 8
# based image with a tightly controlled userspace and glibc 2.28, so binaries
# built inside run on any distro with glibc >= 2.28 (Debian 10, Ubuntu 20.04,
# RHEL 8 and newer). We deliberately do NOT source /hbb_*/activate: Flutter's
# Linux toolchain drives clang itself and HBB's activation flags (hidden
# visibility, static library variants) would interfere with plugin builds.
# The portability comes from building against this old userspace.
FROM docker.io/phusion/holy-build-box:4.0.2

ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

# Provide a writable home directory and download cache for any UID.
RUN mkdir -p /tmp/home /opt/appimage-tools && chmod 777 /tmp/home /opt/appimage-tools

# Extra repositories:
# - CRB (CodeReady Builder, formerly PowerTools) for jsoncpp-devel
# - EPEL for fakeroot
# - RPM Fusion free for mpv-devel (media_kit loads libmpv at runtime)
RUN dnf install -y dnf-plugins-core ca-certificates && \
    (dnf config-manager --set-enabled crb || \
     dnf config-manager --set-enabled powertools || true) && \
    dnf install -y epel-release && \
    dnf install -y \
        https://mirrors.rpmfusion.org/free/el/rpmfusion-free-release-8.noarch.rpm && \
    dnf clean all

# Build dependencies for Flutter Linux + AppImage bundling.
# Note: the stock clang from AppStream is new enough (>= 15) for vodozemac's
# BoringSSL C++17 code, unlike the compilers of older distros.
RUN dnf install -y \
    clang gcc-c++ \
    cmake ninja-build make pkg-config \
    git curl wget unzip xz zip tar gzip which file \
    python3 bison flex gperf \
    gtk3-devel glib2-devel \
    libsecret-devel \
    jsoncpp-devel \
    openssl-devel \
    sqlite-devel \
    pulseaudio-libs-devel \
    libpciaccess-devel \
    xz-devel \
    mpv-libs-devel \
    librsvg2-tools \
    desktop-file-utils fakeroot \
    && dnf clean all

# Fail loudly if the toolchain is too old for vodozemac's BoringSSL.
RUN test "$(clang -dumpversion | cut -d. -f1)" -ge 15 || \
    (echo "clang >= 15 required, found: $(clang --version)" >&2; exit 1)

# Use clang for all CMake/Cargo builds in the container. cc/c++ symlinks cover
# build systems that ignore the CC/CXX environment variables.
ENV CC=clang
ENV CXX=clang++
RUN ln -sf "$(command -v clang)" /usr/local/bin/cc && \
    ln -sf "$(command -v clang++)" /usr/local/bin/c++

# Prevent tar from trying to restore foreign ownership inside rootless containers.
ENV TAR_OPTIONS=--no-same-owner

# Flutter (version pinned to match .tool_versions.yaml and snap/snapcraft.yaml).
ARG FLUTTER_VERSION=3.47.1
RUN git clone --depth 1 --branch "${FLUTTER_VERSION}" \
    https://github.com/flutter/flutter.git /opt/flutter && \
    chmod -R a+rX /opt/flutter && \
    chmod -R a+w /opt/flutter
ENV PATH="/opt/flutter/bin:/opt/flutter/cache/dart-sdk/bin:${PATH}"
# Avoid git "dubious ownership" errors when the container runs as a non-root UID.
RUN git config --system --add safe.directory /opt/flutter && \
    flutter config --enable-linux-desktop && flutter precache --linux && \
    chmod -R a+w /opt/flutter

# Rust (required by flutter_vodozemac). Installed system-wide so any UID can use it.
ENV RUSTUP_HOME=/opt/rustup
ENV CARGO_HOME=/opt/cargo
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- \
    -y --default-toolchain stable --profile minimal --no-modify-path && \
    chmod -R a+rX /opt/rustup /opt/cargo && \
    chmod -R a+w /opt/rustup /opt/cargo
ENV PATH="/opt/cargo/bin:${PATH}"

# AppImage tooling (linuxdeploy + GTK plugin, appimagetool), downloaded at
# image build time so CI builds do not depend on runtime network access to
# GitHub releases. Extracted with --appimage-extract, which needs no FUSE.
# linuxdeploy discovers plugins as executables named linuxdeploy-plugin-<name>
# on PATH, so the GTK plugin is downloaded under exactly that name.
RUN cd /opt/appimage-tools && \
    wget -q https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage && \
    chmod +x linuxdeploy-x86_64.AppImage && \
    ./linuxdeploy-x86_64.AppImage --appimage-extract >/dev/null && \
    mv squashfs-root linuxdeploy && \
    rm linuxdeploy-x86_64.AppImage && \
    wget -q https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage && \
    chmod +x appimagetool-x86_64.AppImage && \
    ./appimagetool-x86_64.AppImage --appimage-extract >/dev/null && \
    mv squashfs-root appimagetool && \
    rm appimagetool-x86_64.AppImage && \
    wget -q -O linuxdeploy-plugin-gtk https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gtk/master/linuxdeploy-plugin-gtk.sh && \
    chmod +x linuxdeploy-plugin-gtk && \
    chmod -R a+rX /opt/appimage-tools
ENV PATH="/opt/appimage-tools:${PATH}"

# SQLCipher, built from source against the EL8 userspace (glibc 2.28, OpenSSL
# 1.1.1). The AppImage bundles this library instead of the system libsqlite3
# so that the encrypted database works: the sqlite3 hook is built with
# `source: system, name: sqlcipher` (see entrypoint.sh) and therefore
# dlopen()s libsqlcipher.so at runtime. OpenSSL is linked dynamically;
# entrypoint.sh bundles EL8's libcrypto.so.1.1, which distros shipping
# OpenSSL 3 (Ubuntu 22.04+ and friends) do not provide.
# Pinned to 4.6.1: 4.7+ requires OpenSSL 3 APIs (EVP_MAC_*), which EL8's
# OpenSSL 1.1.1 does not have. All SQLCipher 4.x releases share the same
# database format, so 4.6.1 reads databases written by newer 4.x versions.
# Kept as the last layer so the expensive Flutter/Rust layers above stay
# cached when the SQLCipher version is bumped. tcl is required by the
# SQLite/SQLCipher build system.
ARG SQLCIPHER_VERSION=4.6.1
RUN dnf install -y tcl && dnf clean all && \
    curl -fL "https://github.com/sqlcipher/sqlcipher/archive/refs/tags/v${SQLCIPHER_VERSION}.tar.gz" \
        -o /tmp/sqlcipher.tar.gz && \
    tar -xzf /tmp/sqlcipher.tar.gz -C /tmp && \
    cd "/tmp/sqlcipher-${SQLCIPHER_VERSION}" && \
    ./configure --prefix=/opt/sqlcipher --enable-tempstore=yes \
        CFLAGS="-O2 -DSQLITE_HAS_CODEC -DSQLCIPHER_CRYPTO_OPENSSL" \
        LDFLAGS="-lcrypto" && \
    make -j"$(nproc)" && \
    make install && \
    cd / && rm -rf /tmp/sqlcipher.tar.gz "/tmp/sqlcipher-${SQLCIPHER_VERSION}"

WORKDIR /build
