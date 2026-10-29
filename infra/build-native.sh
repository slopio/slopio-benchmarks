#!/usr/bin/env bash
# Builds the servers on the client instance Terraform made (infra/), for its
# own CPU, and brings them back to target/native/:
#
#   infra/build-native.sh
#   SERVERS="slopio slopio-native h2o h2o-native" bench/bench.sh single aws
#
# The client and the server are the same Graviton: what -C target-cpu=native
# and -mcpu=native pick on one runs on the other. The client builds because
# it has the CPUs and the memory a fat-LTO build wants, which a c8gn.medium
# has not.
#
# The instance gets no access to GitHub: the workspace goes up with every
# dependency vendored here, slopio's private ones included, and h2o's
# sources at build.sh's revision; it builds offline, with the Rust release
# this machine has.

set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/infra/config.sh"
if [[ ! -f $HOSTS ]]; then
    echo "no instances: terraform -chdir=infra apply first" >&2
    exit 1
fi
source "$HOSTS"

rust=$(rustc -V | awk '{ print $2 }')
stage=$root/target/native-src
rm -rf "$stage"
mkdir -p "$stage/.cargo" "$stage/target" "$root/target/native"

# The sources: the workspace, its dependencies, h2o.
cp -r "$root/Cargo.toml" "$root/Cargo.lock" "$root/servers" "$stage/"
cargo vendor --versioned-dirs --manifest-path "$root/Cargo.toml" "$stage/vendor" |
    sed "s|^directory = .*|directory = \"vendor\"|" > "$stage/.cargo/config.toml"
"$root/servers/h2o/build.sh" > /dev/null # fetches h2o at the pinned revision
tar -C "$root/target" --exclude=h2o-src/build -cf - h2o-src | tar -C "$stage/target" -xf -

echo "sending $(du -sh "$stage" | cut -f1) to $CLIENT_IP"
tar -C "$stage" -czf - . | ssh_to "$CLIENT_IP" "rm -rf native && mkdir native && tar -C native -xzf -"

ssh_to "$CLIENT_IP" "RUST=$rust bash -s" << 'EOF'
set -euo pipefail
sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y -q \
    build-essential cmake pkg-config libssl-dev zlib1g-dev git > /dev/null
if [[ ! -x ~/.cargo/bin/cargo ]]; then
    curl -fsSL https://sh.rustup.rs | sh -s -- -y -q --profile minimal --default-toolchain "$RUST"
fi
source ~/.cargo/env
cd native
echo "$(rustc -V) on $(lscpu | awk -F: '/^Model name/ { gsub(/^ +/, "", $2); print $2 }')"
RUSTFLAGS="-C target-cpu=native" cargo build --release --offline --workspace -q
CFLAGS=-mcpu=native servers/h2o/build.sh
EOF

scp -q "${SSH_OPTS[@]}" "ubuntu@$CLIENT_IP:native/target/release/slopio-server" \
    "ubuntu@$CLIENT_IP:native/target/release/hyper-server" \
    "ubuntu@$CLIENT_IP:native/target/h2o/h2o-server" "$root/target/native/"
ls -l "$root/target/native"
