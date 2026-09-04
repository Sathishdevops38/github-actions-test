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

# ── Egress ────────────────────────────────────────────────────────────────────
# Runners initiate all connections outbound (GitHub APIs, package registries,
# AWS Secrets Manager, CloudWatch, SSM). Allow all outbound so no bootstrap
# step is silently blocked by a missing port rule.
# Inbound is intentionally empty — instances are in private subnets with no
# public IP; SSM Session Manager provides shell access without opening any port.
resource "aws_vpc_security_group_egress_rule" "all_outbound" {
  security_group_id = aws_security_group.runner.id
  description       = "Allow all outbound traffic (NAT Gateway provides internet egress)"
  ip_protocol       = "-1"
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
