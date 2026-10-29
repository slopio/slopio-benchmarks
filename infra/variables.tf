variable "project" {
  description = "Name of every resource, and the Project tag on all of them."
  type        = string
  default     = "slopio-bench"
}

variable "region" {
  type    = string
  default = "eu-west-1"
}

variable "availability_zone" {
  type    = string
  default = "eu-west-1a"
}

# One vCPU for the server, the single-core case; four for h2load, which ran
# out before the server did on the local machine. Other sizes: profiles/.
variable "server_type" {
  type    = string
  default = "c8gn.medium"
}

variable "client_type" {
  type    = string
  default = "c8gn.xlarge"
}

variable "ami_id" {
  description = "Image for both instances. Unset: Canonical's current Ubuntu 24.04 arm64 (glibc 2.39, the one the servers are linked against here)."
  type        = string
  default     = null
}

variable "ssh_cidr" {
  description = "Who may SSH in. Unset: this machine's public address only."
  type        = string
  default     = null
}
