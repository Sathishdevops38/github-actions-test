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
    sid    = "DecryptSecret"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
    ]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "runner_secrets" {
  name   = "${var.name_prefix}-runner-secrets-policy"
  role   = aws_iam_role.runner.id
  policy = data.aws_iam_policy_document.runner_secrets.json
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
