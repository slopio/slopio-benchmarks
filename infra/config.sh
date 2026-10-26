# Shared by up.sh, down.sh, ssh.sh and bench/bench.sh; sourced, not run.
#
# Everything created is tagged Project=slopio-bench, and down.sh removes
# whatever carries the tag.

REGION=${REGION:-eu-west-1}
AZ=${AZ:-eu-west-1a}
PROJECT=slopio-bench

# One vCPU for the server, the single-core case; four for h2load, which ran
# out before the server did on the local machine.
SERVER_TYPE=${SERVER_TYPE:-c8gn.medium}
CLIENT_TYPE=${CLIENT_TYPE:-c8gn.xlarge}

# Canonical's own pointer to its current Ubuntu 24.04 arm64 image: glibc 2.39,
# the one the servers are linked against here.
AMI_PARAM=/aws/service/canonical/ubuntu/server/24.04/stable/current/arm64/hvm/ebs-gp3/ami-id

# The SSH key, the instances' addresses and SSH's own files: local, never
# committed.
STATE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.state
SSH_KEY=$STATE/id_ed25519
HOSTS=$STATE/hosts.env

SSH_OPTS=(
    -i "$SSH_KEY"
    -o UserKnownHostsFile="$STATE/known_hosts"
    -o StrictHostKeyChecking=accept-new
    -o ConnectTimeout=5
    -o ServerAliveInterval=15
    -o LogLevel=ERROR
    # One connection per host, reused by every command of a run.
    -o ControlMaster=auto
    -o ControlPath="$STATE/cm-%C"
    -o ControlPersist=10m
)

aws_() {
    aws --region "$REGION" "$@"
}

ssh_to() {
    local host=$1
    shift
    ssh "${SSH_OPTS[@]}" "ubuntu@$host" "$@"
}
