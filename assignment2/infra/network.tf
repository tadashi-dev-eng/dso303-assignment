# ---------------------------------------------------------------------------
# VPC: 2 AZs x (public, private-app, private-data) subnets
# ---------------------------------------------------------------------------
locals {
  name = "${var.project}-${var.environment}"

  public_cidrs = [cidrsubnet(var.vpc_cidr, 8, 0), cidrsubnet(var.vpc_cidr, 8, 1)]     # 10.20.0.0/24, 10.20.1.0/24
  app_cidrs    = [cidrsubnet(var.vpc_cidr, 4, 1), cidrsubnet(var.vpc_cidr, 4, 2)]     # 10.20.16.0/20, 10.20.32.0/20 (room for Lambda ENIs)
  data_cidrs   = [cidrsubnet(var.vpc_cidr, 8, 200), cidrsubnet(var.vpc_cidr, 8, 201)] # 10.20.200.0/24, 10.20.201.0/24
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${local.name}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-igw" }
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = local.public_cidrs[count.index]
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = false
  tags                    = { Name = "${local.name}-public-${substr(var.azs[count.index], -1, 1)}", Tier = "public" }
}

resource "aws_subnet" "app" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.app_cidrs[count.index]
  availability_zone = var.azs[count.index]
  tags              = { Name = "${local.name}-app-${substr(var.azs[count.index], -1, 1)}", Tier = "private-app" }
}

resource "aws_subnet" "data" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.data_cidrs[count.index]
  availability_zone = var.azs[count.index]
  tags              = { Name = "${local.name}-data-${substr(var.azs[count.index], -1, 1)}", Tier = "private-data" }
}

# Public route table -> Internet Gateway
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-rt-public" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# One NAT gateway per AZ so losing an AZ never removes egress from the other.
resource "aws_eip" "nat" {
  count  = var.enable_nat_gateways ? 2 : 0
  domain = "vpc"
  tags   = { Name = "${local.name}-nat-eip-${count.index}" }
}

resource "aws_nat_gateway" "main" {
  count         = var.enable_nat_gateways ? 2 : 0
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  tags          = { Name = "${local.name}-nat-${substr(var.azs[count.index], -1, 1)}" }
  depends_on    = [aws_internet_gateway.main]
}

# Private app route tables: one per AZ, each pointing at its own AZ's NAT gateway.
resource "aws_route_table" "app" {
  count  = 2
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-rt-app-${substr(var.azs[count.index], -1, 1)}" }
}

resource "aws_route" "app_nat" {
  count                  = var.enable_nat_gateways ? 2 : 0
  route_table_id         = aws_route_table.app[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main[count.index].id
}

resource "aws_route_table_association" "app" {
  count          = 2
  subnet_id      = aws_subnet.app[count.index].id
  route_table_id = aws_route_table.app[count.index].id
}

# Data subnets have no route to the Internet at all.
resource "aws_route_table" "data" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-rt-data" }
}

resource "aws_route_table_association" "data" {
  count          = 2
  subnet_id      = aws_subnet.data[count.index].id
  route_table_id = aws_route_table.data.id
}

# Gateway endpoints: S3 and DynamoDB traffic stays on the AWS network and skips NAT charges.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.app[*].id
  tags              = { Name = "${local.name}-vpce-s3" }
}

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.app[*].id
  tags              = { Name = "${local.name}-vpce-dynamodb" }
}

# ---------------------------------------------------------------------------
# Security groups (least privilege, SG-to-SG references)
# ---------------------------------------------------------------------------
resource "aws_security_group" "lambda" {
  name        = "${local.name}-lambda-sg"
  description = "API and worker Lambda ENIs"
  vpc_id      = aws_vpc.main.id

  egress {
    description = "HTTPS to AWS APIs (via NAT / endpoints)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "PostgreSQL to RDS Proxy"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = local.data_cidrs
  }
}

resource "aws_security_group" "db" {
  name        = "${local.name}-db-sg"
  description = "RDS Proxy and PostgreSQL; only reachable from Lambda"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "PostgreSQL from Lambda"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id]
  }

  ingress {
    description = "Proxy to instance inside the data tier"
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
