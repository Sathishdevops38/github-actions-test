#!/usr/bin/env bash
# =============================================================================
# GitHub Actions Self-Hosted Runner — Bootstrap Script
# Runs on first boot via EC2 user-data (Amazon Linux 2023).
# =============================================================================

# ── Logging setup ─────────────────────────────────────────────────────────────
# Must happen BEFORE set -e so a mkdir/exec failure is still visible.
# cloud-init captures file-descriptor output at the process level; a plain
# redirect (not a tee subshell) is the only reliable way to get logs in
# /var/log/runner-bootstrap.log AND surfaced in cloud-init's own journal.
LOG_FILE="/var/log/runner-bootstrap.log"
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/runner-bootstrap.log"
exec > "$LOG_FILE" 2>&1

# Now it is safe to enable strict mode — all output goes to the log.
set -euo pipefail
set -x   # print every command; makes the log self-documenting

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Starting GitHub Actions runner bootstrap"

# ── Variables (injected by Terraform templatefile()) ─────────────────────────
RUNNER_VERSION="${runner_version}"
GITHUB_OWNER="${github_owner}"
GITHUB_REPO="${github_repo}"
GITHUB_TOKEN_SECRET_ARN="${github_token_secret_arn}"
RUNNER_NAME="${runner_name_prefix}-$(hostname -s)"
RUNNER_LABELS="${runner_labels}"
RUNNER_GROUP="${runner_group}"
AWS_REGION="${aws_region}"
EPHEMERAL="${ephemeral}"
RUNNER_HOME="/opt/actions-runner"

# ── Prerequisites ─────────────────────────────────────────────────────────────
dnf update -y --security
dnf install -y \
  jq \
  git \
  tar \
  perl-Digest-SHA \
  libicu \
  unzip \
  libicu \
  openssl \
  amazon-cloudwatch-agent

# ── Docker Engine ─────────────────────────────────────────────────────────────
# AL2023 ships the core docker package natively; the buildx/compose plugins
# live in Docker's official RHEL9 repo (AL2023 is RHEL9-compatible).
# We pin releasever=9 so dnf resolves the correct RHEL repo metadata.
cat > /etc/yum.repos.d/docker-ce.repo << 'DOCKERREPO'
[docker-ce-stable]
name=Docker CE Stable - $basearch
baseurl=https://download.docker.com/linux/rhel/9/$basearch/stable
enabled=1
gpgcheck=1
gpgkey=https://download.docker.com/linux/rhel/gpg
DOCKERREPO

dnf install -y --allowerasing \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin
systemctl enable --now docker

# ── kubectl ───────────────────────────────────────────────────────────────────
KUBECTL_VERSION="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
if [[ -z "$KUBECTL_VERSION" ]]; then
  echo "ERROR: failed to fetch kubectl stable version" >&2
  exit 1
fi
curl -fsSL "https://dl.k8s.io/release/$KUBECTL_VERSION/bin/linux/amd64/kubectl" \
  -o /usr/local/bin/kubectl
chmod 0755 /usr/local/bin/kubectl

# ── Helm ──────────────────────────────────────────────────────────────────────
# Subshell isolates pipefail; log failure but do not abort the bootstrap.
if ! (curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash); then
  echo "[WARN] Helm install returned non-zero — continuing without Helm" >&2
fi

# ── AWS CLI v2 (pre-installed on AL2023; skip if already present) ─────────────
if ! command -v aws &>/dev/null; then
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" \
    -o /tmp/awscliv2.zip
  unzip -q /tmp/awscliv2.zip -d /tmp
  /tmp/aws/install
  rm -rf /tmp/aws /tmp/awscliv2.zip
fi

# ── Dedicated non-root runner user ────────────────────────────────────────────
if ! id -u runner &>/dev/null; then
  useradd -m -d "$RUNNER_HOME" -s /bin/bash -U runner
fi
# Keep docker group membership current even if user already existed
usermod -aG docker runner

# ── Fetch GitHub PAT from Secrets Manager ────────────────────────────────────
GITHUB_TOKEN=$(aws secretsmanager get-secret-value \
  --secret-id  "$GITHUB_TOKEN_SECRET_ARN" \
  --region     "$AWS_REGION" \
  --query      'SecretString' \
  --output     text)

# ── Download & verify runner tarball ─────────────────────────────────────────
cd "$RUNNER_HOME"
pwd
curl -o actions-runner-linux-x64-2.337.0.tar.gz -L https://github.com/actions/runner/releases/download/v2.337.0/actions-runner-linux-x64-2.337.0.tar.gz
echo "70920811a4f8ad4328818682bca5c6469c1c942fab52448868071d0063816613  actions-runner-linux-x64-2.337.0.tar.gz" | shasum -a 256 -c
tar xzf ./actions-runner-linux-x64-2.337.0.tar.gz
chown -R runner:runner "$RUNNER_HOME"
ls -l

# Register and run the agent as the dedicated non-root user.
set +x
runuser -u runner -- ./config.sh \
  --unattended \
  --url "https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}" \
  --token "$GITHUB_TOKEN"
set -x
runuser -u runner -- bash -c 'nohup ./run.sh > /tmp/actions-runner.log 2>&1 &'

# ── CloudWatch Agent ─────────────────────────────────────────────────────────
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << 'CWCONF'
{
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/runner-bootstrap.log",
            "log_group_name": "/github-actions/runners/${runner_name_prefix}",
            "log_stream_name": "{instance_id}/bootstrap",
            "retention_in_days": 90
          },
          {
            "file_path": "/opt/actions-runner/_diag/Runner_*.log",
            "log_group_name": "/github-actions/runners/${runner_name_prefix}",
            "log_stream_name": "{instance_id}/runner",
            "retention_in_days": 90
          }
        ]
      }
    }
  }
}
CWCONF

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config \
  -m ec2 \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json \
  -s

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Runner bootstrap complete"
