#!/usr/bin/env bash
# Creates the benchmark's two instances, in one cluster placement group so
# that they sit as close as the region allows:
#
#   infra/up.sh     # then bench/bench.sh single aws, then infra/down.sh
#
# Creates, all tagged Project=slopio-bench: an SSH key pair, a security group
# (SSH from this machine's address only, everything between the two
# instances), a placement group, and the instances. They run until
# infra/down.sh: nothing stops them on its own.

set -euo pipefail
source "$(dirname "$0")/config.sh"

running=$(aws_ ec2 describe-instances \
    --filters "Name=tag:Project,Values=$PROJECT" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text)
if [[ -n $running ]]; then
    echo "already up: $running. infra/down.sh first." >&2
    exit 1
fi

echo "account: $(aws_ sts get-caller-identity --query Arn --output text), region $REGION, zone $AZ"

# The quota counts vCPUs, not instances: say so before AWS refuses.
vcpus() {
    aws_ ec2 describe-instance-types --instance-types "$1" \
        --query 'InstanceTypes[0].VCpuInfo.DefaultVCpus' --output text
}
need=$(($(vcpus "$SERVER_TYPE") + $(vcpus "$CLIENT_TYPE")))
quota=$(aws_ service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A \
    --query 'Quota.Value' --output text)
if ((need > ${quota%.*})); then
    echo "$SERVER_TYPE + $CLIENT_TYPE need $need vCPUs; the On-Demand quota is $quota" >&2
    exit 1
fi

mkdir -p "$STATE"
chmod 700 "$STATE"
tags() {
    echo "ResourceType=$1,Tags=[{Key=Project,Value=$PROJECT}${2:+,$2}]"
}

if [[ ! -f $SSH_KEY ]]; then
    ssh-keygen -q -t ed25519 -N '' -C "$PROJECT" -f "$SSH_KEY"
fi
if ! aws_ ec2 describe-key-pairs --key-names "$PROJECT" > /dev/null 2>&1; then
    aws_ ec2 import-key-pair --key-name "$PROJECT" \
        --public-key-material "fileb://$SSH_KEY.pub" \
        --tag-specifications "$(tags key-pair)" > /dev/null
fi

vpc=$(aws_ ec2 describe-vpcs --filters Name=is-default,Values=true \
    --query 'Vpcs[0].VpcId' --output text)
subnet=$(aws_ ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$vpc" "Name=availability-zone,Values=$AZ" \
    Name=default-for-az,Values=true \
    --query 'Subnets[0].SubnetId' --output text)

sg=$(aws_ ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$vpc" "Name=group-name,Values=$PROJECT" \
    --query 'SecurityGroups[0].GroupId' --output text)
if [[ $sg == None ]]; then
    sg=$(aws_ ec2 create-security-group --group-name "$PROJECT" \
        --description "slopio benchmarks" --vpc-id "$vpc" \
        --tag-specifications "$(tags security-group)" \
        --query GroupId --output text)
    # Anything from one instance to the other.
    aws_ ec2 authorize-security-group-ingress --group-id "$sg" \
        --ip-permissions "IpProtocol=-1,UserIdGroupPairs=[{GroupId=$sg}]" > /dev/null
fi
# SSH from here only. The address may have changed since the group was made;
# a rule already there is refused, and that is fine.
myip=$(curl -fsS https://checkip.amazonaws.com)
aws_ ec2 authorize-security-group-ingress --group-id "$sg" \
    --protocol tcp --port 22 --cidr "$myip/32" > /dev/null 2>&1 || true

if ! aws_ ec2 describe-placement-groups --group-names "$PROJECT" > /dev/null 2>&1; then
    aws_ ec2 create-placement-group --group-name "$PROJECT" --strategy cluster \
        --tag-specifications "$(tags placement-group)" > /dev/null
fi

ami=$(aws_ ssm get-parameter --name "$AMI_PARAM" --query Parameter.Value --output text)

# Nothing may upgrade packages in the middle of a run.
cat > "$STATE/user-data.sh" << 'EOF'
#!/bin/bash
set -eux
systemctl disable --now unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer || true
apt-get -o DPkg::Lock::Timeout=600 update
DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -y \
    nghttp2-client sysstat ethtool
EOF

launch() {
    local role=$1 type=$2
    aws_ ec2 run-instances --image-id "$ami" --instance-type "$type" \
        --key-name "$PROJECT" --security-group-ids "$sg" --subnet-id "$subnet" \
        --placement "GroupName=$PROJECT" \
        --metadata-options HttpTokens=required,HttpEndpoint=enabled \
        --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=16,VolumeType=gp3,DeleteOnTermination=true,Encrypted=true}' \
        --user-data "file://$STATE/user-data.sh" \
        --tag-specifications \
        "$(tags instance "{Key=Role,Value=$role},{Key=Name,Value=$PROJECT-$role}")" \
        "$(tags volume)" \
        --query 'Instances[0].InstanceId' --output text
}

echo "launching $SERVER_TYPE (server) and $CLIENT_TYPE (client) from $ami"
server_id=$(launch server "$SERVER_TYPE")
client_id=$(launch client "$CLIENT_TYPE")
aws_ ec2 wait instance-running --instance-ids "$server_id" "$client_id"

address() {
    aws_ ec2 describe-instances --instance-ids "$1" \
        --query "Reservations[0].Instances[0].$2" --output text
}
cat > "$HOSTS" << EOF
SERVER_ID=$server_id
SERVER_TYPE=$SERVER_TYPE
SERVER_IP=$(address "$server_id" PublicIpAddress)
SERVER_PRIVATE_IP=$(address "$server_id" PrivateIpAddress)
CLIENT_ID=$client_id
CLIENT_TYPE=$CLIENT_TYPE
CLIENT_IP=$(address "$client_id" PublicIpAddress)
CLIENT_PRIVATE_IP=$(address "$client_id" PrivateIpAddress)
EOF
source "$HOSTS"

# Up once SSH answers and the packages are in.
for host in "$SERVER_IP" "$CLIENT_IP"; do
    echo -n "waiting for $host "
    for _ in $(seq 60); do
        ssh_to "$host" true 2> /dev/null && break
        echo -n .
        sleep 5
    done
    ssh_to "$host" cloud-init status --wait > /dev/null
    echo " ready"
done

echo
echo "server $SERVER_TYPE: ssh $SERVER_IP, private $SERVER_PRIVATE_IP"
echo "client $CLIENT_TYPE: ssh $CLIENT_IP, private $CLIENT_PRIVATE_IP"
echo "infra/ssh.sh server|client to log in; infra/down.sh to delete everything."
