# Shared by bench/bench.sh and infra/build-native.sh; sourced, not run.
#
# The instances themselves are Terraform's (infra/*.tf). It writes, in
# infra/.state/, local and never committed: the SSH key, ssh_config, and
# hosts.env, the instances' addresses.

STATE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.state
HOSTS=$STATE/hosts.env

SSH_OPTS=(-F "$STATE/ssh_config")

ssh_to() {
    local host=$1
    shift
    ssh "${SSH_OPTS[@]}" "ubuntu@$host" "$@"
}
