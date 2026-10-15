# One VPC, one public subnet, no NAT gateway. Nodes get public IPv4 only so
# they can reach package mirrors; the security groups admit nothing from the
# internet except SSH to the head node from admin_cidrs. A NAT gateway would
# add ~$33/month for the same egress (docs/adr/0003-network.md).

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  subnet_cidr = cidrsubnet(var.vpc_cidr, 8, 1)
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = var.cluster_name }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = var.cluster_name }
}

resource "aws_subnet" "cluster" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.subnet_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = false

  tags = { Name = "${var.cluster_name}-cluster" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "${var.cluster_name}-public" }
}

resource "aws_route_table_association" "cluster" {
  subnet_id      = aws_subnet.cluster.id
  route_table_id = aws_route_table.public.id
}

# Strip every rule from the VPC's default security group so nothing can be
# launched into it by accident with open access.
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.this.id
}

resource "aws_security_group" "cluster" {
  name_prefix = "${var.cluster_name}-cluster-"
  description = "Intra-cluster traffic: slurm, munge, NFS, torch.distributed"
  vpc_id      = aws_vpc.this.id

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "intra_cluster" {
  security_group_id            = aws_security_group.cluster.id
  referenced_security_group_id = aws_security_group.cluster.id
  ip_protocol                  = "-1"
  description                  = "Any traffic between cluster nodes"
}

# Nodes install packages from Ubuntu, PyPI and PyTorch mirrors at boot, and
# there is no NAT or proxy to narrow egress through (docs/adr/0003-network.md).
#trivy:ignore:AWS-0104
resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.cluster.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Package mirrors and AWS APIs"
}

resource "aws_security_group" "ssh" {
  name_prefix = "${var.cluster_name}-ssh-"
  description = "SSH to the head node from operator addresses only"
  vpc_id      = aws_vpc.this.id

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  for_each = toset(var.admin_cidrs)

  security_group_id = aws_security_group.ssh.id
  cidr_ipv4         = each.value
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  description       = "Operator SSH"
}

# Flow logs record accepted and rejected connections for after-the-fact review.
resource "aws_flow_log" "vpc" {
  vpc_id               = aws_vpc.this.id
  traffic_type         = "ALL"
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.flow.arn
  iam_role_arn         = aws_iam_role.flow_logs.arn
}

# CloudWatch Logs encrypts at rest by default; a customer-managed key is not
# worth $1/month for 7-day flow logs.
#trivy:ignore:AWS-0017
resource "aws_cloudwatch_log_group" "flow" {
  name              = "/${var.cluster_name}/vpc-flow"
  retention_in_days = 7
}
