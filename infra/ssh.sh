#!/usr/bin/env bash
# A shell, or one command, on an instance infra/up.sh made:
#
#   infra/ssh.sh server
#   infra/ssh.sh client uptime

set -euo pipefail
source "$(dirname "$0")/config.sh"
source "$HOSTS"

case ${1:-} in
    server) host=$SERVER_IP ;;
    client) host=$CLIENT_IP ;;
    *)
        echo "usage: $0 server|client [command...]" >&2
        exit 2
        ;;
esac
shift
ssh_to "$host" "$@"
