data "aws_iam_policy_document" "runner_assume_role" {
  statement {
    sid     = "AllowEC2AssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "runner" {
  name               = "${var.name_prefix}-runner-role"
  assume_role_policy = data.aws_iam_policy_document.runner_assume_role.json
  path               = "/"

  tags = var.tags
}

# Allow SSM Session Manager for secure shell access (avoids opening SSH port)
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.runner.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Allow CloudWatch agent to push logs / metrics
resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.runner.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# Allow reading the GitHub runner registration token from Secrets Manager
# and all KMS operations needed to use encrypted EBS volumes at runtime.
data "aws_iam_policy_document" "runner_secrets" {
  statement {
    sid    = "ReadRunnerSecret"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [var.github_token_secret_arn]
  }

  statement {
    sid    = "UseKMSKey"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:CreateGrant",
      "kms:GenerateDataKey",
      "kms:GenerateDataKeyWithoutPlaintext",
      "kms:ReEncrypt*",
    ]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "runner_secrets" {
  name   = "${var.name_prefix}-runner-secrets-policy"
  role   = aws_iam_role.runner.id
  policy = data.aws_iam_policy_document.runner_secrets.json
}

# --------------------------------------------------------------------------
# KMS key policy grant — allows the EC2 Auto Scaling service to use the KMS
# key when launching instances with encrypted EBS volumes via the ASG.
# Without this, the ASG cannot attach encrypted volumes and instances fail
# to start with "KMS key inaccessible" errors.
# --------------------------------------------------------------------------
data "aws_iam_policy_document" "asg_kms_grant" {
  statement {
    sid    = "AllowASGServiceKMSAccess"
    effect = "Allow"
    actions = [
      "kms:CreateGrant",
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:GenerateDataKeyWithoutPlaintext",
      "kms:ReEncrypt*",
    ]
    resources = [var.kms_key_arn]

    principals {
      type        = "Service"
      identifiers = ["autoscaling.amazonaws.com"]
    }
  }
}

resource "aws_kms_grant" "asg" {
  name              = "${var.name_prefix}-asg-ebs-grant"
  key_id            = var.kms_key_arn
  grantee_principal = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling"

  operations = [
    "CreateGrant",
    "Decrypt",
    "DescribeKey",
    "GenerateDataKeyWithoutPlaintext",
    "ReEncryptFrom",
    "ReEncryptTo",
  ]
}

data "aws_caller_identity" "current" {}

# --------------------------------------------------------------------------
# KMS key policy — allows CloudWatch Logs service principal to use the key.
# aws_kms_grant does not support service principals (only IAM role/user ARNs);
# a key policy statement is required for logs.amazonaws.com.
#
# aws_kms_key_policy REPLACES the entire key policy, so we must read the
# existing policy first and merge our new statement into it via
# source_policy_documents — otherwise the root/admin statements are stripped
# and KMS rejects the update with MalformedPolicyDocumentException.
# --------------------------------------------------------------------------
data "aws_region" "current" {}

data "aws_kms_key_policy" "runners" {
  key_id = var.kms_key_arn
}

data "aws_iam_policy_document" "kms_cloudwatch_logs" {
  # Preserve every statement already in the key policy
  source_policy_documents = [data.aws_kms_key_policy.runners.policy]

  # Add the CloudWatch Logs service principal statement
  statement {
    sid    = "AllowCloudWatchLogsKMS"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey",
      "kms:DescribeKey",
    ]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["logs.${data.aws_region.current.name}.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:*"]
    }
  }
}

resource "aws_kms_key_policy" "cloudwatch_logs" {
  key_id = var.kms_key_arn
  policy = data.aws_iam_policy_document.kms_cloudwatch_logs.json
}

# Optional: allow runner to push ECR images / describe ECR (append additional
# managed policies via var.extra_policy_arns if needed)
resource "aws_iam_role_policy_attachment" "extra" {
  for_each   = toset(var.extra_policy_arns)
  role       = aws_iam_role.runner.name
  policy_arn = each.value
}

resource "aws_iam_instance_profile" "runner" {
  name = "${var.name_prefix}-runner-profile"
  role = aws_iam_role.runner.name

  tags = var.tags
}
