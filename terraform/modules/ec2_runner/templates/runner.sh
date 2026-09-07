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

# ── SSM Agent — enable before anything else ───────────────────────────────────
# amazon-ssm-agent is pre-installed on AL2023 but not always running after
# user-data starts. Enable and start it immediately so Session Manager
# connections are available as soon as the instance reaches the network.
# The agent reaches SSM endpoints via the NAT Gateway (no VPC endpoints needed).
systemctl enable amazon-ssm-agent
systemctl start  amazon-ssm-agent

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

# ── Download & verify runner tarball ─────────────────────────────────────────
# Registration is handled by the run_registered.sh wrapper on every cycle.
# The bootstrap only needs to download and extract the runner binary.
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

# ── Re-registration wrapper ───────────────────────────────────────────────────
# Because the runner must re-register with a fresh GitHub token before every
# run.sh invocation, we write a small wrapper script that:
#   1. Removes any stale .runner config left from the previous job
#   2. Fetches a new registration token from Secrets Manager
#   3. Calls config.sh --replace to register the runner
#   4. Exec's run.sh — which picks up one job then exits cleanly
#
# The systemd unit calls this wrapper with Restart=always so the cycle repeats
# automatically: job done → run.sh exits → systemd restarts wrapper → runner
# re-registers → picks up next job. The runner is always visible in GitHub
# Settings → Runners between jobs (registered, idle state).

# Terraform placeholders ($${var}) are substituted at plan/apply time.
# Every bash $ that must survive to runtime is escaped as \$.
cat > /opt/actions-runner/run_registered.sh << WRAPPER
#!/bin/bash
set -euo pipefail

RUNNER_HOME="/opt/actions-runner"
cd "\$RUNNER_HOME"

GITHUB_TOKEN_SECRET_ARN="${github_token_secret_arn}"
AWS_REGION="${aws_region}"
GITHUB_OWNER="${github_owner}"
GITHUB_REPO="${github_repo}"
RUNNER_NAME="${runner_name_prefix}-\$(hostname -s)"
RUNNER_LABELS="${runner_labels}"
RUNNER_GROUP="${runner_group}"

# Fetch a fresh registration token from Secrets Manager
GITHUB_API_TOKEN_RAW=\$(aws secretsmanager get-secret-value \
  --secret-id  "\$GITHUB_TOKEN_SECRET_ARN" \
  --region     "\$AWS_REGION" \
  --query      'SecretString' \
  --output     text)

if echo "\$GITHUB_API_TOKEN_RAW" | jq -e . >/dev/null 2>&1; then
  GITHUB_API_TOKEN=\$(echo "\$GITHUB_API_TOKEN_RAW" | jq -r 'if has("token") then .token elif has("github_token") then .github_token else ([.. | strings | select(startswith("ghp_") or startswith("github_pat_"))] | first) // ([.. | strings] | first) end')
  [ -z "\$GITHUB_API_TOKEN" ] && GITHUB_API_TOKEN="\$GITHUB_API_TOKEN_RAW"
else
  GITHUB_API_TOKEN="\$GITHUB_API_TOKEN_RAW"
fi

GITHUB_URL="https://github.com/\$GITHUB_OWNER"
[ -n "\$GITHUB_REPO" ] && GITHUB_URL="\$GITHUB_URL/\$GITHUB_REPO"

if [[ -z "\$GITHUB_REPO" ]]; then
  REG_API="https://api.github.com/orgs/\$GITHUB_OWNER/actions/runners/registration-token"
else
  REG_API="https://api.github.com/repos/\$GITHUB_OWNER/\$GITHUB_REPO/actions/runners/registration-token"
fi

REG_TOKEN=\$(curl -fsSL -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer \$GITHUB_API_TOKEN" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  -H "Content-Length: 0" \
  "\$REG_API" | jq -er '.token')

# Remove stale config so config.sh --replace can succeed cleanly
rm -f "\$RUNNER_HOME/.runner" "\$RUNNER_HOME/.credentials" "\$RUNNER_HOME/.credentials_rsaparams"

./config.sh \
  --unattended \
  --replace \
  --url     "\$GITHUB_URL" \
  --token   "\$REG_TOKEN" \
  --name    "\$RUNNER_NAME" \
  --labels  "\$RUNNER_LABELS" \
  --runnergroup "\$RUNNER_GROUP"

exec ./run.sh
WRAPPER

chmod 0755 /opt/actions-runner/run_registered.sh
chown ec2-user:ec2-user /opt/actions-runner/run_registered.sh

# ── systemd service unit ──────────────────────────────────────────────────────
# Restart=always — after each job run.sh exits cleanly (exit 0); systemd
# restarts the wrapper which re-registers the runner and picks up the next job.
# The runner remains visible in GitHub Settings → Runners between jobs.

cat > /etc/systemd/system/github-runner.service << 'UNIT'
[Unit]
Description=GitHub Actions Self-Hosted Runner
After=network-online.target docker.service
Wants=network-online.target docker.service

[Service]
Type=simple
User=ec2-user
WorkingDirectory=/opt/actions-runner
ExecStart=/opt/actions-runner/run_registered.sh

# Restart after every exit (clean job completion OR crash)
Restart=always
RestartSec=5s

# Graceful shutdown — give the runner 30 s to finish / deregister
KillMode=process
KillSignal=SIGTERM
TimeoutStopSec=30

# Resource guards
LimitNOFILE=65536
LimitNPROC=4096

# Route all output through journald so CloudWatch agent can collect it
StandardOutput=journal
StandardError=journal
SyslogIdentifier=github-runner

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now github-runner.service

# ── Health-check: wait for the runner service to become active ────────────────
# Gives up to 60 s before declaring the bootstrap done. A failure here is
# non-fatal (the service itself will keep retrying), but it surfaces early
# in the bootstrap log so operators can diagnose registration issues quickly.
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Waiting for github-runner.service to become active..."
for i in $(seq 1 12); do
  if systemctl is-active --quiet github-runner.service; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] github-runner.service is active (attempt $i/12)"
    break
  fi
  echo "  ... not active yet ($i/12), retrying in 5 s"
  sleep 5
done

# ── CloudWatch Agent ─────────────────────────────────────────────────────────
# The runner service logs are collected via journald (not a flat file) so that
# stdout/stderr from every job is captured reliably without needing a separate
# log-rotation scheme.
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << CWCONF
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
