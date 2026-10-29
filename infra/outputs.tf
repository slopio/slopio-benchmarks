output "server" {
  value = {
    type       = aws_instance.this["server"].instance_type
    public_ip  = aws_instance.this["server"].public_ip
    private_ip = aws_instance.this["server"].private_ip
  }
}

output "client" {
  value = {
    type       = aws_instance.this["client"].instance_type
    public_ip  = aws_instance.this["client"].public_ip
    private_ip = aws_instance.this["client"].private_ip
  }
}

output "ssh" {
  value = "ssh -F infra/.state/ssh_config server|client"
}
