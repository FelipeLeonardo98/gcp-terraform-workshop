# Deploy to GCP with Terraform Using GitHub Actions (Secure WIF Setup)

![GCP WIF](gcp-wif.png)

## Overview

This project demonstrates how to securely deploy GCP infrastructure with Terraform, using **GitHub Actions** and **Workload Identity Federation (WIF)** — **no static service account keys needed**.  
Follow these steps to set up secure CI/CD, get temporary GCP credentials, and protect your Terraform state.

---

## 🗺️ Architecture

1. **GitHub Actions** requests a short-lived OIDC token.
2. **GCP Workload Identity** trusts that OIDC token (configured as a Provider).
3. The workflow **impersonates a service account** and gets temporary credentials.
4. **Terraform** runs and manages infrastructure securely.

> **Key tech:** Terraform, GitHub Actions, WIF, No static service account keys

---

## 📖 Detailed Documentation

For in-depth explanation of the bootstrap script and GCP services being created, see [Bootstrap WIF Script Guide](bootstrap_wif_guide.md).

---

## 1️⃣ GCP Setup

### a. Run the Bootstrap Script ([`bootstrap_wif.sh`](bootstrap_wif.sh))

Creates all necessary WIF resources for GitHub Actions authentication.

**Quick setup:**
```bash
PROJECT_ID="your-project-id" REPO="owner/repository-name" PROVIDER_SCOPE="repo" ./bootstrap_wif.sh
```

**What it creates:**
- ✅ Service Account with minimal permissions
- ✅ Workload Identity Pool & GitHub OIDC Provider  
- ✅ Custom IAM role for bucket creation
- ✅ Terraform state bucket (secure, versioned)

**Output:** Copy these values for your GitHub repository variables.

### 2. Terraform Configuration ([`main.tf`](main.tf))

Example Terraform configuration that creates storage buckets using the service account created by the bootstrap script.

<details>
<summary>Click to expand Terraform configuration</summary>

```hcl
terraform {
  required_providers {
    google = { source = "hashicorp/google", version = "~> 5.0" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

variable "project_id" {
  type = string
}

variable "app_bucket_location" {
  type    = string
  default = "EU"
}

provider "google" { project = var.project_id }

resource "random_id" "suffix" { byte_length = 2 }

resource "google_storage_bucket" "app" {
  name                        = "${var.project_id}-app-${random_id.suffix.hex}"
  location                    = var.app_bucket_location
  force_destroy               = true
  uniform_bucket_level_access = true
}
```

</details>

---

## 2️⃣ Write the Terraform

See [`main.tf`](main.tf), [`backend.tf`](backend.tf) for the full Terraform configuration.

**Example:**

<details>
<summary>Storage bucket (Excerpt from <code>main.tf</code>)</summary>

```hcl
resource "google_storage_bucket" "app" {
  name                        = "${var.project_id}-app-${random_id.suffix.hex}"
  location                    = var.app_bucket_location
  force_destroy               = true
  uniform_bucket_level_access = true
}
```
</details>

<details>
<summary>GCS Backend (Excerpt from <code>backend.tf</code>)</summary>

```hcl
terraform {
  backend "gcs" {
    bucket = "tfstate-34947"
    prefix = "terraform/state"
  }
}
```
</details>

> **Tip:**  
> - Always enable bucket versioning and uniform bucket-level access.  
> - Add proper `provider "google"` configuration as needed.

---

## 3️⃣ GitHub Actions Workflow

The complete workflow is in [`.github/workflows/wif-auth-smoke.yml`](.github/workflows/wif-auth-smoke.yml).

### a. Store Values as Repository Variables

- Go to: **GitHub repo → Settings → Secrets and variables → Actions → Variables**
- Add these repository variables:  
  - **Name:** `GCP_PROJECT_ID` **Value:** *(Your GCP project ID)*
  - **Name:** `GCP_PROJECT_NUMBER` **Value:** *(From bootstrap output)*
  - **Name:** `TF_STATE_BUCKET` **Value:** *(From bootstrap output)*

---

### b. Create Workflow File

Example GitHub Actions workflow for Terraform deployment with WIF authentication.

<details>
<summary>Click to expand workflow configuration</summary>

```yaml
name: Terraform Deploy with WIF
on:
  pull_request:
    branches: ["main"]
    types: [opened, synchronize, reopened]
  push:
    branches: [main]
  workflow_dispatch:

permissions:
  id-token: write
  contents: read
  pull-requests: write
  issues: write

jobs:
  terraform:
    runs-on: ubuntu-latest
    env:
  GCP_PROJECT_ID: ${{ secrets.GCP_PROJECT_ID }}
  GCP_PROJECT_NUMBER: ${{ secrets.GCP_PROJECT_NUMBER }}
  TF_STATE_BUCKET: ${{ secrets.TF_STATE_BUCKET }}
    steps:
      - uses: actions/checkout@v4

      - id: auth
        uses: google-github-actions/auth@v2
        with:
          workload_identity_provider: projects/${{ env.GCP_PROJECT_NUMBER }}/locations/global/workloadIdentityPools/gh-pool/providers/YOUR_PROVIDER_ID
          service_account: YOUR_SERVICE_ACCOUNT@${{ env.GCP_PROJECT_ID }}.iam.gserviceaccount.com
          export_environment_variables: true

      - name: Setup gcloud
        uses: google-github-actions/setup-gcloud@v2
        with:
          project_id: ${{ env.GCP_PROJECT_ID }}

      - name: Verify authentication
        run: |
          gcloud auth list --filter=status:ACTIVE --format="value(account)"
          gcloud config get-value project
          echo "Authenticated as: $(gcloud auth list --filter=status:ACTIVE --format='value(account)')"
          echo "Project: $(gcloud config get-value project)"

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "1.8.0"

      - name: Terraform Init
        run: terraform init

      - name: Terraform Format check
        run: terraform fmt

      - name: Terraform Plan
        id: plan
        run: |
          set -o pipefail
          terraform plan -no-color -detailed-exitcode -var="project_id=${{ env.GCP_PROJECT_ID }}" | tee tfplan.txt
          echo "exitcode=$?" >> $GITHUB_OUTPUT
        continue-on-error: true

      - name: Comment Terraform Plan on PR
        uses: actions/github-script@v7
        if: (steps.plan.outcome == 'success' || steps.plan.outcome == 'failure') && !(github.event_name == 'push' && github.ref == 'refs/heads/main')
        with:
          script: |
            const fs = require('fs');
            let prNumber;
            if (context.eventName === 'pull_request') {
              prNumber = context.payload.pull_request.number;
            } else {
              const branchName = context.ref.replace('refs/heads/', '');
              const prs = await github.rest.pulls.list({
                owner: context.repo.owner,
                repo: context.repo.repo,
                head: `${context.repo.owner}:${branchName}`,
                state: 'open'
              });
              if (!prs.data.length) return;
              prNumber = prs.data[0].number;
            }
            
            const planOutput = fs.readFileSync('tfplan.txt', 'utf8');
            const summaryMatch = planOutput.match(/Plan: (\d+) to add, (\d+) to change, (\d+) to destroy./);
            let summary = summaryMatch ? 
              `\`\`\`\nCreate: ${summaryMatch[1]}\nUpdate: ${summaryMatch[2]}\nDelete: ${summaryMatch[3]}\n\`\`\`` :
              /No changes/.test(planOutput) ? '```\nCreate: 0\nUpdate: 0\nDelete: 0\n```' : '⚠️ Could not parse summary';
            
            const body = [
              "## 🏗️ Terraform Plan Summary",
              summary,
              `<details><summary>Show Plan Details</summary>\n\n\`\`\`hcl\n${planOutput.slice(0, 60000)}\n\`\`\`\n</details>`,
              `\n**Branch:** \`${context.ref.replace('refs/heads/', '')}\` | **Pusher:** @${context.actor}`
            ].join("\n");
            
            await github.rest.issues.createComment({
              issue_number: prNumber,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body
            });

      - name: Fail if Terraform Plan failed
        if: steps.plan.outputs.exitcode == '1'
        run: |
          echo "❌ Terraform plan failed"
          exit 1

      - name: Terraform Apply
        if: github.ref == 'refs/heads/main' && github.event_name == 'push'
        run: terraform apply -auto-approve -var="project_id=${{ env.GCP_PROJECT_ID }}"
        
      - name: List created buckets
        run: gcloud storage buckets list --project "$GCP_PROJECT_ID" --format="value(name)"
```

</details>

Replace `YOUR_PROVIDER_ID` and `YOUR_SERVICE_ACCOUNT` with values from the bootstrap script output.

---

## 4️⃣ Enable GitHub Branch Protection

- Go to: **Settings → Branches → Add rule**
  - Rule pattern: `main`
  - Enable:
    - ✔️ Require a pull request before merging
    - ✔️ Require approvals
    - ✔️ Dismiss stale pull request approvals when new commits are pushed
    - ✔️ Require approval of the most recent reviewable push
    - ✔️ Require status checks to pass before merging
    - ✔️ Require branches to be up to date before merging
    - ✔️ Require conversation resolution before merging
    - ✔️ Require signed commits
    - ✔️ Require linear history

---

## 🚀 Demo (How This Works)

- **Open a PR** → Workflow runs `terraform plan` and **comments the plan summary** with:
  - 📊 Resource counts (Create/Update/Delete)
  - 🔍 Collapsible full plan details
  - ✅ Format validation (`terraform fmt`)
- **Merge to `main`** → Workflow runs `terraform apply` and deploys changes
- **Check GCP Console** → Resources appear (e.g., storage buckets)

---

## 🔒 Security Notes

- **No static service account keys** anywhere.
- OIDC tokens are short-lived.
- GCS state is private, encrypted, and versioned.
- Branch protection enforces a secure and collaborative workflow by requiring code reviews, status checks, and other safeguards before changes reach your main branch.
- **Note:** Service accounts have minimal permissions (custom bucket creator role + object viewer).

---

## ⭐ Recap

- **Created**: Secure WIF setup with service account & OIDC provider
- **Built**: GitHub Actions workflow with WIF authentication  
- **Stored**: Terraform state in secure, private GCS bucket
- **Protected**: Your main branch with GitHub branch protection
- **Deployed**: GCP infrastructure with minimal permissions

---

## 🧹 Cleanup

When you're done, use the cleanup script ([`cleanup.sh`](cleanup.sh)) to remove all resources:

```bash
./cleanup.sh PROJECT_ID SA_NAME POOL_ID PROVIDER_ID BUCKET_NAME CUSTOM_ROLE_ID
```

**Example:**
```bash
./cleanup.sh wedogcp gha-deployer-22124 gh-pool-22124 github-22124 tfstate-22124 bucketCreator_22124
```