locals {
  runner_labels = join(",", concat(["self-hosted", var.runner_os, var.runner_arch], var.extra_runner_labels))
}

# --------------------------------------------------------------------------
# User-data bootstrap script — installs the GitHub Actions runner and
# registers it against the repository or organisation defined in variables.
# The registration token is fetched at boot from Secrets Manager.
# --------------------------------------------------------------------------

# NOTE: aws_secretsmanager_secret_version is intentionally NOT read here.
# Reading it on every plan causes the user_data hash to change whenever the
# secret is rotated, which triggers a launch template update and instance
# refresh (EC2 recreation). The actual secret value is fetched at instance
# boot by the user-data script and is never stored in Terraform state.

data "aws_region" "current" {}

locals {
  user_data = base64encode(templatefile("${path.module}/templates/runner.sh", {
    github_owner            = var.github_owner
    github_repo             = var.github_repo
    github_token_secret_arn = var.github_token_secret_arn
    runner_name_prefix      = var.name_prefix
    runner_labels           = local.runner_labels
    runner_group            = var.runner_group
    runner_version          = var.runner_version
    aws_region              = data.aws_region.current.name
    ephemeral               = var.ephemeral_runners
  }))

  # SHA-256 of the rendered user_data used as a change trigger.
  # When user_data changes this hash changes → launch template is updated →
  # instance_refresh fires → running instances are replaced with the new config.
  user_data_hash = sha256(local.user_data)
}

# --------------------------------------------------------------------------
# Launch Template
# --------------------------------------------------------------------------
resource "aws_launch_template" "runner" {
  # Use name_prefix (not name) so that create_before_destroy can create the
  # new launch template before the old one is deleted. A static name causes
  # InvalidLaunchTemplateName.AlreadyExistsException when both exist briefly.
  name_prefix   = "${var.name_prefix}-runner-lt-"
  image_id      = var.ami_id
  instance_type = var.instance_type

  iam_instance_profile {
    name = var.instance_profile_name
  }

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [var.security_group_id]
    delete_on_termination       = true
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.root_volume_size_gb
      volume_type           = "gp3"
      encrypted             = true
      kms_key_id            = var.kms_key_arn
      delete_on_termination = true
    }
  }

  metadata_options {
    # IMDSv2 enforced — instance metadata requires a signed token
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
  }

  monitoring {
    enabled = true
  }

  user_data = local.user_data

  tag_specifications {
    resource_type = "instance"
    tags = merge(var.tags, {
      Name = "${var.name_prefix}-runner"
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(var.tags, {
      Name = "${var.name_prefix}-runner-vol"
    })
  }

  lifecycle {
    create_before_destroy = true
    # Force a new launch template version (and therefore an instance refresh)
    # whenever user_data content changes. Without this, in-place LT updates
    # do not always propagate to the ASG's instance refresh trigger.
    replace_triggered_by = [terraform_data.user_data_version]
  }

  tags = var.tags
}

# Sentinel resource — its value is the user_data hash. When user_data changes
# the hash changes, this resource is replaced, and the launch template
# replace_triggered_by fires, guaranteeing a fresh LT version every time.
resource "terraform_data" "user_data_version" {
  input = local.user_data_hash
}

# --------------------------------------------------------------------------
# Auto Scaling Group
# --------------------------------------------------------------------------
resource "aws_autoscaling_group" "runner" {
  name                      = "${var.name_prefix}-runner-asg"
  min_size                  = var.min_runners
  max_size                  = var.max_runners
  desired_capacity          = var.desired_runners
  vpc_zone_identifier       = var.subnet_ids
  health_check_type         = "EC2"
  health_check_grace_period = 120
  wait_for_capacity_timeout = "10m"

  launch_template {
    id      = aws_launch_template.runner.id
    version = "$Latest"
  }

  instance_refresh {
    strategy = "Rolling"
    # Only trigger a rolling replacement when user_data actually changes.
    # Without explicit triggers, any launch template version bump (tags,
    # metadata tweaks, etc.) would replace all running instances.
    triggers = ["launch_template"]
    preferences {
      min_healthy_percentage = 50
    }
  }

  dynamic "tag" {
    for_each = merge(var.tags, {
      Name                  = "${var.name_prefix}-runner"
      "github:runner-group" = var.runner_group
    })
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [desired_capacity]
  }
}

# --------------------------------------------------------------------------
# Scale-out policy (CPU-based) — scale up when average CPU > 70%
# --------------------------------------------------------------------------
resource "aws_autoscaling_policy" "scale_out" {
  name                   = "${var.name_prefix}-runner-scale-out"
  autoscaling_group_name = aws_autoscaling_group.runner.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 70.0
  }
}

# --------------------------------------------------------------------------
# CloudWatch Log Group for runner bootstrap logs
# --------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "runner" {
  name              = "/github-actions/runners/${var.name_prefix}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn

  tags = var.tags
}
