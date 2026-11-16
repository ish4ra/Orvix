#!/usr/bin/env bash
# Builds the macOS Free P2P engine for the architecture of this machine.
#
#   tools/build_macos_stream_engine.sh <output directory>
#
# The engine is the upstream stream server at a pinned commit, prepared by
# tools/patch_macos_stream_engine.py, linked statically against libtorrent
# and OpenSSL so that it depends only on macOS itself. The result is
# <output directory>/orvix-stream-server plus BUILD_INFO.txt.
#
# A universal engine is made by building on an Apple Silicon and an Intel
# machine and joining the two with lipo (tools/bundle_macos_stream_engine.sh).
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "usage: $0 <output directory>" >&2
  exit 2
fi
out=$1
here=$(cd "$(dirname "$0")" && pwd)
work=${ORVIX_ENGINE_WORK:-${RUNNER_TEMP:-/tmp}/orvix-stream-engine}
arch=$(uname -m)

STREAM_SERVER_REPO=https://github.com/stremio-native/stream-server.git
STREAM_SERVER_TAG=v0.1.8
STREAM_SERVER_COMMIT=4f29c489ee38820f80166267ebc71538bf50e63d
LIBTORRENT_VERSION=2.0.11
LIBTORRENT_SHA256=f0db58580f4f29ade6cc40fa4ba80e2c9a70c90265cd77332d3cdec37ecf1e6d
# Oldest macOS the engine is built to run on.
export MACOSX_DEPLOYMENT_TARGET=11.0

rm -rf "$work"
mkdir -p "$work" "$out"

export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1
brew install boost openssl@3 cmake pkg-config
boost=$(brew --prefix boost)
openssl=$(brew --prefix openssl@3)

# A view of OpenSSL that holds only the static libraries. The linker prefers
# a .dylib when both are in one directory, and an engine linked against
# Homebrew's .dylib would not start on a Mac without Homebrew.
ssl="$work/openssl-static"
mkdir -p "$ssl/lib/pkgconfig"
ln -s "$openssl/include" "$ssl/include"
cp "$openssl/lib/libssl.a" "$openssl/lib/libcrypto.a" "$ssl/lib/"
for pc in openssl libssl libcrypto; do
  sed -e "s|^prefix=.*|prefix=$ssl|" -e 's|^exec_prefix=.*|exec_prefix=${prefix}|' \
    -e 's|^libdir=.*|libdir=${exec_prefix}/lib|' -e 's|^includedir=.*|includedir=${prefix}/include|' \
    "$openssl/lib/pkgconfig/$pc.pc" > "$ssl/lib/pkgconfig/$pc.pc"
done

# libtorrent, static.
tarball="$work/libtorrent.tar.gz"
curl -fL --retry 3 -o "$tarball" \
  "https://github.com/arvidn/libtorrent/releases/download/v$LIBTORRENT_VERSION/libtorrent-rasterbar-$LIBTORRENT_VERSION.tar.gz"
echo "$LIBTORRENT_SHA256  $tarball" | shasum -a 256 -c -
mkdir -p "$work/libtorrent-src"
tar -xzf "$tarball" -C "$work/libtorrent-src" --strip-components=1
libtorrent="$work/libtorrent"
cmake -S "$work/libtorrent-src" -B "$work/libtorrent-build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$libtorrent" \
  -DCMAKE_OSX_ARCHITECTURES="$arch" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DBUILD_SHARED_LIBS=OFF \
  -Dpython-bindings=OFF -Dexamples=OFF -Dtests=OFF -Dtools=OFF \
  -Dencryption=ON \
  -DOPENSSL_ROOT_DIR="$ssl" -DOPENSSL_USE_STATIC_LIBS=ON \
  -DCMAKE_PREFIX_PATH="$boost;$ssl"
cmake --build "$work/libtorrent-build" --config Release --parallel 4
cmake --install "$work/libtorrent-build" --config Release
test -f "$libtorrent/lib/pkgconfig/libtorrent-rasterbar.pc"

# The stream server, at the pinned commit.
git clone --depth 1 --branch "$STREAM_SERVER_TAG" "$STREAM_SERVER_REPO" "$work/stream-server"
actual=$(git -C "$work/stream-server" rev-parse HEAD)
if [ "$actual" != "$STREAM_SERVER_COMMIT" ]; then
  echo "stream server $STREAM_SERVER_TAG is at $actual, expected $STREAM_SERVER_COMMIT." >&2
  exit 1
fi
python3 "$here/patch_macos_stream_engine.py" "$work/stream-server"

export PKG_CONFIG_PATH="$libtorrent/lib/pkgconfig:$ssl/lib/pkgconfig"
export LIBTORRENT_RASTERBAR_STATIC=1
export OPENSSL_STATIC=1 OPENSSL_DIR="$ssl"
export CXXFLAGS="-I$boost/include -I$ssl/include ${CXXFLAGS:-}"
export CPPFLAGS="-I$boost/include -I$ssl/include ${CPPFLAGS:-}"
export CPLUS_INCLUDE_PATH="$boost/include:$ssl/include:${CPLUS_INCLUDE_PATH:-}"
export LDFLAGS="-L$libtorrent/lib -L$ssl/lib ${LDFLAGS:-}"
(cd "$work/stream-server" && cargo build --release --package server --bin server)

engine="$out/orvix-stream-server"
cp "$work/stream-server/target/release/server" "$engine"
chmod 755 "$engine"

# It must run on a Mac that has nothing but macOS.
if otool -L "$engine" | tail -n +2 | awk '{print $1}' |
  grep -vE '^(/usr/lib/|/System/Library/)' ; then
  echo "The engine depends on the libraries listed above, which are not part of macOS." >&2
  exit 1
fi
built=$(lipo -archs "$engine")
if [ "$built" != "$arch" ]; then
  echo "The engine was built for '$built', expected '$arch'." >&2
  exit 1
fi

{
  echo "stream server: $STREAM_SERVER_TAG ($STREAM_SERVER_COMMIT)"
  echo "libtorrent: $LIBTORRENT_VERSION (static)"
  echo "openssl: $(basename "$(readlink "$openssl" || echo "$openssl")") (static)"
  echo "architecture: $built"
  echo "minimum macOS: $MACOSX_DEPLOYMENT_TARGET"
  echo "built on: $(sw_vers -productName) $(sw_vers -productVersion)"
} > "$out/BUILD_INFO.txt"
cat "$out/BUILD_INFO.txt"
