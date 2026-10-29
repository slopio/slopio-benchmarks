# The benchmark's two instances, server and client, in one cluster placement
# group so that they sit as close as the region allows. They run, and are
# billed, until `terraform destroy`.

locals {
  state_dir = abspath("${path.module}/.state")

  instances = {
    server = var.server_type
    client = var.client_type
  }

  ami_id   = coalesce(var.ami_id, one(data.aws_ssm_parameter.ubuntu[*].insecure_value))
  ssh_cidr = coalesce(var.ssh_cidr, "${chomp(one(data.http.my_ip[*].response_body))}/32")
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnet" "default" {
  vpc_id            = data.aws_vpc.default.id
  availability_zone = var.availability_zone
  default_for_az    = true
}

data "aws_ssm_parameter" "ubuntu" {
  count = var.ami_id == null ? 1 : 0
  name  = "/aws/service/canonical/ubuntu/server/24.04/stable/current/arm64/hvm/ebs-gp3/ami-id"
}

data "http" "my_ip" {
  count = var.ssh_cidr == null ? 1 : 0
  url   = "https://checkip.amazonaws.com"
}

# SSH

resource "tls_private_key" "ssh" {
  algorithm = "ED25519"
}

resource "aws_key_pair" "this" {
  key_name   = var.project
  public_key = tls_private_key.ssh.public_key_openssh
}

# Network: SSH from ssh_cidr, anything between the two instances.

resource "aws_security_group" "this" {
  name        = var.project
  description = "slopio benchmarks"
  vpc_id      = data.aws_vpc.default.id
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  security_group_id = aws_security_group.this.id
  cidr_ipv4         = local.ssh_cidr
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
}

resource "aws_vpc_security_group_ingress_rule" "between" {
  security_group_id            = aws_security_group.this.id
  referenced_security_group_id = aws_security_group.this.id
  ip_protocol                  = "-1"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.this.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_placement_group" "this" {
  name     = var.project
  strategy = "cluster"
}

# Instances

resource "aws_instance" "this" {
  for_each = local.instances

  ami                    = local.ami_id
  instance_type          = each.value
  subnet_id              = data.aws_subnet.default.id
  vpc_security_group_ids = [aws_security_group.this.id]
  placement_group        = aws_placement_group.this.name
  key_name               = aws_key_pair.this.key_name

  user_data                   = file("${path.module}/cloud-init.yaml")
  user_data_replace_on_change = true

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_size           = 16
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name = "${var.project}-${each.key}"
    Role = each.key
  }

  # A newer Ubuntu published mid-session must not replace running instances.
  lifecycle {
    ignore_changes = [ami]
  }
}

# Ready once SSH answers and cloud-init has installed the packages.
resource "terraform_data" "ready" {
  for_each = aws_instance.this

  triggers_replace = [each.value.id]

  connection {
    host        = each.value.public_ip
    user        = "ubuntu"
    private_key = tls_private_key.ssh.private_key_openssh
  }

  provisioner "remote-exec" {
    inline = ["cloud-init status --wait > /dev/null"]
  }
}

# What bench/bench.sh and `ssh -F infra/.state/ssh_config server` read.
# Local, never committed; deleted by `terraform destroy`.

resource "local_sensitive_file" "ssh_key" {
  filename             = "${local.state_dir}/id_ed25519"
  content              = tls_private_key.ssh.private_key_openssh
  file_permission      = "0600"
  directory_permission = "0700"
}

resource "local_file" "ssh_config" {
  filename             = "${local.state_dir}/ssh_config"
  file_permission      = "0600"
  directory_permission = "0700"
  content = templatefile("${path.module}/ssh_config.tftpl", {
    state = local.state_dir
    instances = {
      for role, instance in aws_instance.this :
      role => { id = instance.id, public_ip = instance.public_ip }
    }
  })
}

resource "local_file" "hosts" {
  filename             = "${local.state_dir}/hosts.env"
  file_permission      = "0600"
  directory_permission = "0700"
  content              = <<-EOT
    SERVER_ID=${aws_instance.this["server"].id}
    SERVER_TYPE=${aws_instance.this["server"].instance_type}
    SERVER_IP=${aws_instance.this["server"].public_ip}
    SERVER_PRIVATE_IP=${aws_instance.this["server"].private_ip}
    CLIENT_ID=${aws_instance.this["client"].id}
    CLIENT_TYPE=${aws_instance.this["client"].instance_type}
    CLIENT_IP=${aws_instance.this["client"].public_ip}
    CLIENT_PRIVATE_IP=${aws_instance.this["client"].private_ip}
  EOT

  # Written last: its presence is what tells bench.sh the instances are up.
  depends_on = [terraform_data.ready, local_sensitive_file.ssh_key, local_file.ssh_config]
}
