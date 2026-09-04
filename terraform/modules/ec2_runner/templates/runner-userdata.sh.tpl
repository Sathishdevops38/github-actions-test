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
  unzip \
  libicu \
  openssl \
  amazon-cloudwatch-agent

# ── Docker Engine ─────────────────────────────────────────────────────────────
# Write the repo file directly with curl — no dnf config-manager needed.
# --allowerasing lets dnf replace curl-minimal with the full curl package
# that docker-ce-cli requires.
curl -fsSL https://download.docker.com/linux/amzn/docker-ce.repo \
  -o /etc/yum.repos.d/docker-ce.repo
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
# Subshell + || true: prevents pipefail from treating a non-zero exit
# from get-helm-3 (e.g. "already installed" path) as a fatal error.
(curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash) || true

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
RUNNER_ARCHIVE="actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
RUNNER_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${RUNNER_ARCHIVE}"

mkdir -p "$RUNNER_HOME"
curl -fsSL "$RUNNER_URL" -o "/tmp/$RUNNER_ARCHIVE"

# Fetch the SHA-256 sidecar published alongside every runner release
RUNNER_CHECKSUM=$(curl -fsSL \
  "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz.sha256" \
  | awk '{print $1}')
echo "$RUNNER_CHECKSUM  /tmp/$RUNNER_ARCHIVE" | sha256sum -c -

tar -xzf "/tmp/$RUNNER_ARCHIVE" -C "$RUNNER_HOME"
rm -f "/tmp/$RUNNER_ARCHIVE"
chown -R runner:runner "$RUNNER_HOME"

# ── Registration URL & token ──────────────────────────────────────────────────
if [[ -n "$GITHUB_REPO" ]]; then
  REGISTRATION_URL="https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}"
  TOKEN_ENDPOINT="https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/actions/runners/registration-token"
else
  REGISTRATION_URL="https://github.com/${GITHUB_OWNER}"
  TOKEN_ENDPOINT="https://api.github.com/orgs/${GITHUB_OWNER}/actions/runners/registration-token"
fi

RUNNER_TOKEN=$(curl -fsSL \
  -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "$TOKEN_ENDPOINT" | jq -r '.token')

# ── Configure the runner ──────────────────────────────────────────────────────
EPHEMERAL_FLAG=""
if [[ "$EPHEMERAL" == "true" ]]; then
  EPHEMERAL_FLAG="--ephemeral"
fi

sudo -u runner bash -c "
  set -euo pipefail
  cd '$RUNNER_HOME'
  ./config.sh \
    --unattended \
    --url         '$REGISTRATION_URL' \
    --token       '$RUNNER_TOKEN' \
    --name        '$RUNNER_NAME' \
    --labels      '$RUNNER_LABELS' \
    --runnergroup '$RUNNER_GROUP' \
    --work        '_work' \
    $EPHEMERAL_FLAG
"

# ── Install runner as a systemd service ───────────────────────────────────────
# svc.sh resolves ./runsvc.sh and ./.service relative to CWD — must cd first.
cd "$RUNNER_HOME"
./svc.sh install runner
./svc.sh start

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
