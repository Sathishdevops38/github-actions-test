# GitHub Actions Self-Hosted Runners — Terraform

Provisions ephemeral GitHub Actions self-hosted runner instances on AWS using
an Auto Scaling Group, with encrypted EBS volumes, IAM least-privilege, and
SSM Session Manager access (no open SSH ports).

---

## Folder Structure

```
terraform/
├── modules/
│   ├── vpc/                  # VPC, subnets, IGW, NAT Gateway, route tables
│   ├── security_group/       # Runner SG (HTTPS egress only, no inbound)
│   ├── iam/                  # Runner IAM role, instance profile, policies
│   └── ec2_runner/           # Launch template, ASG, CloudWatch log group
│       └── templates/
│           └── runner-userdata.sh.tpl   # Boot script — installs & registers runner
└── environments/
    └── prod/
        ├── providers.tf          # AWS provider + S3 backend declaration
        ├── main.tf               # Root module — wires all child modules
        ├── variables.tf          # All input variables
        ├── outputs.tf            # Key resource IDs / ARNs
        ├── backend.hcl           # Backend config (not committed with real values)
        └── terraform.tfvars.example   # Copy → terraform.tfvars, fill in values
```

---

## Prerequisites

| Tool | Minimum version |
|------|----------------|
| Terraform | 1.8.0 |
| AWS CLI | 2.x |
| AWS Account | OIDC provider configured for GitHub Actions |

### AWS resources that must pre-exist

| Resource | Purpose |
|----------|---------|
| S3 bucket | Terraform remote state + native lock file |
| KMS key (`alias/terraform-state`) | S3 state encryption |
| IAM OIDC role | GitHub Actions → AWS authentication |

### GitHub repository secrets / variables

| Name | Type | Description |
|------|------|-------------|
| `AWS_ROLE_ARN` | Secret | ARN of the OIDC role the workflow assumes |
| `TF_STATE_BUCKET` | Secret | S3 bucket name for Terraform state |
| `TF_STATE_KMS_KEY_ID` | Secret | KMS key ID/alias for state bucket encryption |
| `GH_RUNNER_ORG` | Secret | GitHub organisation or user (runner owner) |
| `AWS_REGION` | Variable | AWS region (e.g. `us-east-1`) |
| `RUNNER_AMI_ID` | Variable | AMI ID for runner instances (Amazon Linux 2023) |

---

## First-Time Setup

### 1 — Store the GitHub PAT in Secrets Manager

```bash
aws secretsmanager create-secret \
  --name "/gh-runner/github-runner-token" \
  --description "GitHub PAT with repo / admin:org scope for runner registration" \
  --secret-string "ghp_XXXXXXXXXXXXXXXXXXXX" \
  --kms-key-id alias/gh-runner-runner
```

> The KMS key is created by Terraform on first `apply`. Run `apply` once
> without the PAT, then store the secret, then run `apply` again (idempotent).

### 2 — Copy and fill in tfvars

```bash
cd terraform/environments/prod
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars — fill in github_owner, runner_ami_id, etc.
```

### 3 — Initialise and apply locally (optional)

```bash
terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

---

## GitHub Actions Workflow

The workflow at `.github/workflows/terraform-runners.yml` has four jobs:

| Job | Trigger | What it does |
|-----|---------|-------------|
| **validate** | Every push / PR | `fmt -check`, `init -backend=false`, `validate` |
| **plan** | PRs, push to main, manual `plan` | Full plan; posts diff as PR comment |
| **apply** | Push to `main`, manual `apply` | Applies the saved plan binary |
| **destroy** | Manual `destroy` only | Tears down all runner infrastructure |

`apply` and `destroy` are gated by GitHub **Environments** — configure
required reviewers in **Settings → Environments → prod** (and `prod-destroy`).

---

## Security Controls

- **IMDSv2 enforced** on all launch templates (`http_tokens = "required"`)
- **No SSH port open** — shell access via SSM Session Manager only
- **EBS volumes encrypted** with a dedicated per-environment KMS key
- **Secrets Manager** stores the GitHub PAT — never in Terraform state
- **Non-root user** (`runner`) runs the agent process
- **Ephemeral runners** — each instance handles one job, then terminates
- **OIDC authentication** — no long-lived AWS credentials in CI secrets
- **TLS 1.2+** for all GitHub API calls (system default on Amazon Linux 2023)
