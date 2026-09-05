#!/bin/bash
# =============================================================================
# GitHub Actions Self-Hosted Runner — Bootstrap Script
# Runs on first boot via EC2 user-data (Amazon Linux 2023).
# =============================================================================

# ── Logging setup ─────────────────────────────────────────────────────────────
LOG_FILE="/var/log/runner-bootstrap.log"
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/runner-bootstrap.log"
exec > "$LOG_FILE" 2>&1

# Strict mode — exit on error, unbound variable, or pipe failure.
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
dnf update -y
dnf install -y \
  jq \
  git \
  tar \
  perl-Digest-SHA \
  libicu \
  unzip \
  openssl \
  amazon-cloudwatch-agent

# ── Docker Engine ─────────────────────────────────────────────────────────────
# AL2023 ships the core docker package natively; the buildx/compose plugins
# live in Docker's official RHEL9 repo (AL2023 is RHEL9-compatible).
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

# ── Runner user ───────────────────────────────────────────────────────────────
# Amazon Linux 2023 provides the non-root ec2-user account.
usermod -aG docker ec2-user

# ── Fetch GitHub PAT from Secrets Manager ────────────────────────────────────
set +x   # suppress secret values from the log
GITHUB_API_TOKEN_RAW=$(aws secretsmanager get-secret-value \
  --secret-id  "$GITHUB_TOKEN_SECRET_ARN" \
  --region     "$AWS_REGION" \
  --query      'SecretString' \
  --output     text)

# If the retrieved secret is a JSON string, try to parse it with jq.
# It checks for common keys like 'token' or 'github_token'.
# If jq is not successful or keys do not exist, fall back to the raw string.
if echo "$GITHUB_API_TOKEN_RAW" | jq -e . >/dev/null 2>&1; then
  GITHUB_API_TOKEN=$(echo "$GITHUB_API_TOKEN_RAW" | jq -r 'if has("token") then .token elif has("github_token") then .github_token else empty end')
  if [[ -z "$GITHUB_API_TOKEN" ]]; then
    GITHUB_API_TOKEN="$GITHUB_API_TOKEN_RAW"
  fi
else
  GITHUB_API_TOKEN="$GITHUB_API_TOKEN_RAW"
fi

# GitHub requires a short-lived registration token, not a PAT, for config.sh.
# Org-level when GITHUB_REPO is empty; repo-level otherwise.
if [[ -z "$GITHUB_REPO" ]]; then
  GITHUB_API_URL="https://api.github.com/orgs/$${GITHUB_OWNER}/actions/runners/registration-token"
else
  GITHUB_API_URL="https://api.github.com/repos/$${GITHUB_OWNER}/$${GITHUB_REPO}/actions/runners/registration-token"
fi
if ! GITHUB_TOKEN=$(curl -fsSL --retry 3 --connect-timeout 10 --max-time 30 \
  -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer $GITHUB_API_TOKEN" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  -H "User-Agent: github-actions-runner-bootstrap" \
  -H "Content-Length: 0" \
  "$GITHUB_API_URL" | jq -er '.token'); then
  echo "ERROR: GitHub token cannot create a runner registration token. Verify the token permissions and GitHub owner/repository configuration." >&2
  exit 1
fi
set -x

# ── Download & verify runner tarball ─────────────────────────────────────────
mkdir -p "$RUNNER_HOME"
cd "$RUNNER_HOME"

RUNNER_ARCHIVE="actions-runner-linux-x64-$${RUNNER_VERSION}.tar.gz"
curl -fsSL "https://github.com/actions/runner/releases/download/v$${RUNNER_VERSION}/$${RUNNER_ARCHIVE}" \
  -o "$${RUNNER_ARCHIVE}"

# The SHA-256 checksum is embedded in the GitHub release body, not a separate
# asset file.  Extract it via the API and verify before extracting.
RUNNER_SHA=$(curl -fsSL --retry 3 \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/actions/runner/releases/tags/v$${RUNNER_VERSION}" \
  | grep -oP '(?<=<!-- BEGIN SHA linux-x64 -->)[a-f0-9]{64}(?=<!-- END SHA linux-x64 -->)')
if [[ -z "$RUNNER_SHA" ]]; then
  echo "ERROR: could not extract SHA-256 for runner v$${RUNNER_VERSION} from GitHub release body" >&2
  exit 1
fi
echo "$${RUNNER_SHA}  $${RUNNER_ARCHIVE}" | shasum -a 256 -c

tar xzf "$${RUNNER_ARCHIVE}"
chown -R ec2-user:ec2-user "$RUNNER_HOME"

# ── Register the runner ───────────────────────────────────────────────────────
GITHUB_URL="https://github.com/$${GITHUB_OWNER}"
if [[ -n "$GITHUB_REPO" ]]; then
  GITHUB_URL="$${GITHUB_URL}/$${GITHUB_REPO}"
fi

set +x   # suppress token from log
RUNNER_CONFIG_ARGS=(
  --unattended
  --url "$GITHUB_URL"
  --token "$GITHUB_TOKEN"
  --name "$RUNNER_NAME"
  --labels "$RUNNER_LABELS"
  --runnergroup "$RUNNER_GROUP"
)
if [[ "$EPHEMERAL" == "true" ]]; then
  RUNNER_CONFIG_ARGS+=(--ephemeral)
fi
runuser -u ec2-user -- ./config.sh "$${RUNNER_CONFIG_ARGS[@]}"
set -x

# Start the runner as ec2-user in the background so user-data can complete.
runuser -u ec2-user -- bash -c 'nohup ./run.sh > /tmp/actions-runner.log 2>&1 &'

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
