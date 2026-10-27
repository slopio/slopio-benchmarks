#!/usr/bin/env bash
# Builds target/h2o/h2o-server: libh2o (the epoll flavour, h2o's own release
# flags, -O2) from h2o's sources at a fixed revision, and server.c linked
# against it and the system's OpenSSL and zlib.
#
#   servers/h2o/build.sh
#
# Needs git, cmake, a C compiler, and OpenSSL's and zlib's headers
# (libssl-dev, zlib1g-dev). Ubuntu 24.04's libssl3 and zlib1g, there by
# default, run the result.

set -euo pipefail

H2O_REPO=https://github.com/h2o/h2o.git
H2O_REV=8c95f0682c3ff573c8ab6451ed3587b82eb15a4d

root=$(cd "$(dirname "$0")/../.." && pwd)
src=$root/target/h2o-src
out=$root/target/h2o

if [[ ! -d $src/.git ]]; then
    git clone -q "$H2O_REPO" "$src"
fi
if [[ $(git -C "$src" rev-parse HEAD) != "$H2O_REV" ]]; then
    git -C "$src" fetch -q --depth 1 origin "$H2O_REV"
    git -C "$src" checkout -q "$H2O_REV"
fi

cmake -S "$src" -B "$src/build" -DCMAKE_BUILD_TYPE=Release -DWITH_MRUBY=OFF -DWITH_BUNDLED_SSL=OFF > /dev/null
make -C "$src/build" -s -j"$(nproc)" libh2o-evloop

includes=()
for dir in include deps/picotls/include deps/quicly/include deps/klib deps/yoml deps/picohttpparser build; do
    includes+=("-I$src/$dir")
done
mkdir -p "$out"
cc -std=gnu11 -O2 -pthread -Wall -DH2O_USE_LIBUV=0 "${includes[@]}" "$root/servers/h2o/server.c" \
    "$src/build/libh2o-evloop.a" -lssl -lcrypto -lz -lm -o "$out/h2o-server"
echo "$out/h2o-server (h2o $H2O_REV)"
