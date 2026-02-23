terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}



provider "aws" {
  region = "us-east-1"
}


data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

locals {
  name = var.name_prefix
  az1  = data.aws_availability_zones.available.names[0]
  az2  = data.aws_availability_zones.available.names[1]
}

# -------------------------
# VPC + Internet
# -------------------------
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${local.name}-vpc"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${local.name}-igw"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name = "${local.name}-public-rt"
  }
}

# -------------------------
# Two Public Subnets (2 AZs)
# -------------------------
resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_a_cidr
  availability_zone       = local.az1
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.name}-public-a"
  }
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_b_cidr
  availability_zone       = local.az2
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.name}-public-b"
  }
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}

# -------------------------
# Security Groups
# -------------------------
# ALB SG: allow inbound HTTP 80 from internet
resource "aws_security_group" "alb_sg" {
  name        = "${local.name}-alb-sg"
  description = "ALB security group"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTP from internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name}-alb-sg" }
}

# EC2 SG: allow HTTPS 443 from ALB, and (optional) from your IP for direct testing
resource "aws_security_group" "ec2_sg" {
  name        = "${local.name}-ec2-sg"
  description = "EC2 security group"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "HTTPS from ALB"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  # Optional: allow you to hit instance public IP directly over HTTPS
  # Set var.my_ip_cidr = "x.x.x.x/32" (your public IP)
  ingress {
    description = "Direct HTTPS from my IP (optional)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.my_ip_cidr == "" ? [] : [var.my_ip_cidr]
  }

  # Optional: allow SSH from your IP (only if you set my_ip_cidr and key_name)
  ingress {
    description = "SSH from my IP (optional)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.my_ip_cidr == "" ? [] : [var.my_ip_cidr]
  }

  egress {
    description = "All egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name}-ec2-sg" }
}

# -------------------------
# User Data: HTTPS Welcome page (self-signed cert)
# -------------------------
locals {
  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail

    dnf -y update
    dnf -y install nginx openssl

    # Create a self-signed cert for nginx
    mkdir -p /etc/nginx/ssl
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
      -subj "/C=US/ST=TX/L=Dallas/O=POC/OU=IT/CN=localhost" \
      -keyout /etc/nginx/ssl/server.key \
      -out /etc/nginx/ssl/server.crt

    INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
    AZ=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)
    IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 || true)

    cat > /usr/share/nginx/html/index.html <<HTML
    <html>
      <head><title>Welcome</title></head>
      <body style="font-family: Arial, sans-serif;">
        <h1>Welcome from $${INSTANCE_ID}</h1>
        <p>AZ: $${AZ}</p>
        <p>Public IP: $${IP}</p>
        <p>Served over HTTPS (self-signed).</p>
      </body>
    </html>
    HTML

    cat > /etc/nginx/conf.d/https.conf <<'NGINX'
    server {
      listen 443 ssl;
      server_name _;

      ssl_certificate     /etc/nginx/ssl/server.crt;
      ssl_certificate_key /etc/nginx/ssl/server.key;

      location / {
        root   /usr/share/nginx/html;
        index  index.html;
      }
    }
    NGINX

    # Remove default server on 80 (keep instance only on 443)
    rm -f /etc/nginx/conf.d/default.conf || true

    systemctl enable nginx
    systemctl restart nginx
  EOF
}

# -------------------------
# EC2 Instances (one per subnet)
# -------------------------
resource "aws_instance" "web_a" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.public_a.id
  vpc_security_group_ids = [aws_security_group.ec2_sg.id]
  key_name               = var.key_name == "" ? null : var.key_name
  user_data              = local.user_data

  tags = { Name = "${local.name}-web-a" }
}

resource "aws_instance" "web_b" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.public_b.id
  vpc_security_group_ids = [aws_security_group.ec2_sg.id]
  key_name               = var.key_name == "" ? null : var.key_name
  user_data              = local.user_data

  tags = { Name = "${local.name}-web-b" }
}

# -------------------------
# ALB + Target Group + Listener (HTTP -> HTTPS targets)
# -------------------------
resource "aws_lb" "this" {
  name               = "${local.name}-alb"
  load_balancer_type = "application"
  internal           = false

  security_groups = [aws_security_group.alb_sg.id]
  subnets         = [aws_subnet.public_a.id, aws_subnet.public_b.id]

  tags = { Name = "${local.name}-alb" }
}

resource "aws_lb_target_group" "https_tg" {
  name     = "${local.name}-tg"
  port     = 443
  protocol = "HTTPS"
  vpc_id   = aws_vpc.this.id

  health_check {
    protocol            = "HTTPS"
    port                = "443"
    path                = "/"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
    interval            = 15
    matcher             = "200-399"
  }

  tags = { Name = "${local.name}-tg" }
}

resource "aws_lb_target_group_attachment" "a" {
  target_group_arn = aws_lb_target_group.https_tg.arn
  target_id        = aws_instance.web_a.id
  port             = 443
}

resource "aws_lb_target_group_attachment" "b" {
  target_group_arn = aws_lb_target_group.https_tg.arn
  target_id        = aws_instance.web_b.id
  port             = 443
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.https_tg.arn
  }
}

# -------------------------
# Outputs
# -------------------------
output "alb_dns_name" {
  value = aws_lb.this.dns_name
}

output "instance_a_public_ip" {
  value = aws_instance.web_a.public_ip
}

output "instance_b_public_ip" {
  value = aws_instance.web_b.public_ip
}