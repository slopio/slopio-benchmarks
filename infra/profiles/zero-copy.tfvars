# protocols/zero-copy.md: 50 Gbit/s sustained on both sides, no burst
# credits to run out; 16 vCPUs for h2load to receive it. The server runs on
# CPU 0 only (SERVER_CPUS=0).
#
#   terraform -chdir=infra apply -var-file=profiles/zero-copy.tfvars
server_type = "c8gn.4xlarge"
client_type = "c8gn.4xlarge"
