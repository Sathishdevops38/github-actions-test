resource "aws_security_group" "runner" {
  name        = "${var.name_prefix}-runner-sg"
  description = "Security group for GitHub Actions self-hosted runner instances"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-runner-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# Runners must reach GitHub APIs and package registries (HTTPS outbound only).
# No inbound rules are needed — SSM Session Manager provides shell access
# without opening port 22.
resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.runner.id
  description       = "Allow HTTPS outbound (GitHub, package registries)"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
  tags              = var.tags
}

resource "aws_vpc_security_group_egress_rule" "http" {
  security_group_id = aws_security_group.runner.id
  description       = "Allow HTTP outbound (package mirrors)"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
  tags              = var.tags
}

# Optional: allow runners in the same SG to communicate (e.g. Docker-in-Docker
# sidecars). Disabled by default; set var.allow_intra_sg_communication = true.
resource "aws_vpc_security_group_ingress_rule" "intra_sg" {
  count                        = var.allow_intra_sg_communication ? 1 : 0
  security_group_id            = aws_security_group.runner.id
  description                  = "Allow intra-runner communication"
  ip_protocol                  = "-1"
  referenced_security_group_id = aws_security_group.runner.id
  tags                         = var.tags
}
