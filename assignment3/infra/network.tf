# ---------------------------------------------------------------------------
# VPC: only the data tier lives here now (Assignment 3 change C3).
# The Lambdas reach Aurora through the RDS Data API (HTTPS) and every other service through
# its public AWS endpoint, so they run outside the VPC. That removes both NAT gateways, the
# public and app subnets and the Internet gateway: about USD 87/month and one class of
# single point of failure (a NAT gateway is zonal).
# ---------------------------------------------------------------------------
locals {
  name       = "${var.project}-${var.environment}"
  data_cidrs = [cidrsubnet(var.vpc_cidr, 8, 200), cidrsubnet(var.vpc_cidr, 8, 201)] # 10.20.200.0/24, 10.20.201.0/24
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${local.name}-vpc" }
}

# Private data subnets, one per AZ. No Internet gateway, no NAT, no route out.
resource "aws_subnet" "data" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.data_cidrs[count.index]
  availability_zone = var.azs[count.index]
  tags              = { Name = "${local.name}-data-${substr(var.azs[count.index], -1, 1)}", Tier = "private-data" }
}

resource "aws_route_table" "data" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-rt-data" }
}

resource "aws_route_table_association" "data" {
  count          = 2
  subnet_id      = aws_subnet.data[count.index].id
  route_table_id = aws_route_table.data.id
}

# The Data API talks to the cluster from inside AWS, so the database security group has
# no ingress from anywhere except other members of the cluster.
resource "aws_security_group" "db" {
  name        = "${local.name}-db-sg"
  description = "Aurora cluster; reachable only through the RDS Data API"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Cluster members"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = local.data_cidrs
  }
}
