#!/usr/bin/env bash
# Deletes everything infra/up.sh made: the instances and their disks, the
# placement group, the security group and the key pair. Safe to run twice,
# or after an up.sh that failed half way.

set -euo pipefail
source "$(dirname "$0")/config.sh"

ids=$(aws_ ec2 describe-instances \
    --filters "Name=tag:Project,Values=$PROJECT" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down" \
    --query 'Reservations[].Instances[].InstanceId' --output text)
if [[ -n $ids ]]; then
    echo "terminating $ids"
    # shellcheck disable=SC2086
    aws_ ec2 terminate-instances --instance-ids $ids > /dev/null
    # shellcheck disable=SC2086
    aws_ ec2 wait instance-terminated --instance-ids $ids
fi

# Only once the instances are gone: a group still in use cannot be deleted.
if aws_ ec2 describe-placement-groups --group-names "$PROJECT" > /dev/null 2>&1; then
    echo "deleting placement group $PROJECT"
    aws_ ec2 delete-placement-group --group-name "$PROJECT"
fi

for sg in $(aws_ ec2 describe-security-groups \
    --filters "Name=tag:Project,Values=$PROJECT" \
    --query 'SecurityGroups[].GroupId' --output text); do
    echo "deleting security group $sg"
    # Network interfaces are released a little after termination.
    for _ in $(seq 12); do
        aws_ ec2 delete-security-group --group-id "$sg" 2> /dev/null && break
        sleep 5
    done
done

if aws_ ec2 describe-key-pairs --key-names "$PROJECT" > /dev/null 2>&1; then
    echo "deleting key pair $PROJECT"
    aws_ ec2 delete-key-pair --key-name "$PROJECT"
fi

rm -f "$HOSTS" "$STATE/known_hosts" "$STATE/user-data.sh" "$SSH_KEY" "$SSH_KEY.pub"
rm -f "$STATE"/cm-*

# What would still be billed: volumes that outlived their instance.
left=$(aws_ ec2 describe-volumes --filters "Name=tag:Project,Values=$PROJECT" \
    --query 'Volumes[].VolumeId' --output text)
if [[ -n $left ]]; then
    echo "still there, and billed: volumes $left" >&2
    exit 1
fi
echo "nothing of $PROJECT is left in $REGION"
