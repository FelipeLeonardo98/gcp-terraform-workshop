#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# GitHub → GCP (WIF/OIDC) bootstrap (idempotent)
# Creates:
#   • Service Account (SA)
#   • Workload Identity Pool + GitHub OIDC Provider
#   • Provider-level attribute condition (owner | repo | repo+ref)
#   • SA WIU binding with repo+branch condition
#   • Optional: Terraform state bucket (versioned, UBLA) + object-only IAM
# Prints: workload_identity_provider, service_account, project_number, tf_state_bucket (if created)
# ------------------------------------------------------------

# ======= EDIT / env / flags =======
PROJECT_ID="${PROJECT_ID:-your-gcp-project-id}"

# GitHub trust
REPO="${REPO:-owner/repo}"                 # e.g. yourname/gha-wif-demo
BRANCH="${BRANCH:-refs/heads/main}"        # exact Git ref to allow
REPO_OWNER="${REPO_OWNER:-${REPO%%/*}}"    # derived from REPO by default

# WIF objects with random suffix for global uniqueness
RANDOM_SUFFIX="${RANDOM_SUFFIX:-$(date +%s | tail -c 6)}"
SA_NAME="${SA_NAME:-gha-deployer-${RANDOM_SUFFIX}}"
POOL_ID="${POOL_ID:-gh-pool-${RANDOM_SUFFIX}}"
PROVIDER_ID="${PROVIDER_ID:-github-${RANDOM_SUFFIX}}"

# Provider guard scope: owner | repo | repo-ref
PROVIDER_SCOPE="${PROVIDER_SCOPE:-owner}"

# Terraform state bucket controls
CREATE_TFSTATE="${CREATE_TFSTATE:-1}"                     # 1=create; 0=skip
STATE_BUCKET_LOCATION="${STATE_BUCKET_LOCATION:-us-east1}"  # London region
RETENTION_DAYS="${RETENTION_DAYS:-0}"                     # 0=off; >0 sets bucket retention

# Demo runtime role for visible payoff (list buckets). Keep least-privilege in prod.
CUSTOM_ROLE_ID="bucketCreator_${RANDOM_SUFFIX}"
RUNTIME_ROLES_DEFAULT=("roles/storage.objectViewer" "projects/${PROJECT_ID}/roles/${CUSTOM_ROLE_ID}" "roles/iam.serviceAccountTokenCreator")
RUNTIME_ROLES=("${RUNTIME_ROLES[@]:-${RUNTIME_ROLES_DEFAULT[@]}}")

# ======= Flags =======
while getopts ":p:r:b:o:s:P:V:S:L:" opt; do
  case $opt in
    p) PROJECT_ID="$OPTARG" ;;
    r) REPO="$OPTARG" ;;
    b) BRANCH="$OPTARG" ;;
    o) REPO_OWNER="$OPTARG" ;;
    s) SA_NAME="$OPTARG" ;;
    P) POOL_ID="$OPTARG" ;;
    V) PROVIDER_ID="$OPTARG" ;;
    S) PROVIDER_SCOPE="$OPTARG" ;;   # owner | repo | repo-ref
    L) STATE_BUCKET_LOCATION="$OPTARG" ;;
    \?) echo "Usage: $0 [-p project] [-r owner/repo] [-b ref] [-o owner] [-s sa] [-P pool] [-V provider] [-S owner|repo|repo-ref] [-L bucket_location]"; exit 2 ;;
  esac
done

# ======= Preflight =======
command -v gcloud >/dev/null || { echo "gcloud not found"; exit 1; }
gcloud config set project "$PROJECT_ID" >/dev/null
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"

SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
WIP_PARENT="projects/${PROJECT_NUMBER}/locations/global"
WIP_PATH="${WIP_PARENT}/workloadIdentityPools/${POOL_ID}"
PROVIDER_RESOURCE="${WIP_PATH}/providers/${PROVIDER_ID}"
PRINCIPAL_SET="principalSet://iam.googleapis.com/${WIP_PATH}/*"
TF_STATE_BUCKET="tfstate-${RANDOM_SUFFIX}"

# Build provider attribute condition
case "$PROVIDER_SCOPE" in
  owner)    PROVIDER_ATTR_COND="attribute.repository_owner=='${REPO_OWNER}'" 
            SA_CONDITION="request.auth.claims['repository_owner']=='${REPO_OWNER}'" ;;
  repo)     PROVIDER_ATTR_COND="attribute.repository=='${REPO}'" 
            SA_CONDITION="request.auth.claims['repository']=='${REPO}'" ;;
  repo-ref) PROVIDER_ATTR_COND="attribute.repository=='${REPO}' && attribute.ref=='${BRANCH}'" 
            SA_CONDITION="request.auth.claims['repository']=='${REPO}' && request.auth.claims['ref']=='${BRANCH}'" ;;
  *) echo "Invalid PROVIDER_SCOPE: $PROVIDER_SCOPE (use owner|repo|repo-ref)"; exit 2 ;;
esac

echo "============================================================="
echo "GitHub → GCP Workload Identity Federation Bootstrap"
echo "============================================================="
echo
echo "This script will create/configure the following resources:"
echo
echo "  1. Required APIs:"
echo "     • iam.googleapis.com"
echo "     • iamcredentials.googleapis.com"
echo "     • sts.googleapis.com"
echo "     • storage.googleapis.com"
echo
echo "  2. Custom IAM Role:"
echo "     • ${CUSTOM_ROLE_ID}"
echo "       (Permissions: storage.buckets.*)"
echo
echo "  3. Service Account:"
echo "     • ${SA_EMAIL}"
echo
echo "  4. Runtime IAM Roles (granted to SA):"
for role in "${RUNTIME_ROLES[@]}"; do
  echo "     • $role"
done
echo
echo "  5. Workload Identity Pool:"
echo "     • Pool ID: ${POOL_ID}"
echo "     • Location: global"
echo
echo "  6. OIDC Provider (GitHub):"
echo "     • Provider ID: ${PROVIDER_ID}"
echo "     • Issuer: https://token.actions.githubusercontent.com"
echo "     • Attribute condition: ${PROVIDER_ATTR_COND}"
echo
echo "  7. IAM Bindings on Service Account:"
echo "     • roles/iam.workloadIdentityUser"
echo "       (Condition: ${SA_CONDITION})"
echo "     • roles/iam.serviceAccountTokenCreator (x2)"
echo
if [[ "$CREATE_TFSTATE" == "1" ]]; then
echo "  8. Terraform State Bucket:"
echo "     • gs://${TF_STATE_BUCKET}"
echo "     • Location: ${STATE_BUCKET_LOCATION}"
echo "     • Versioning: enabled"
echo "     • Uniform bucket-level access: enabled"
[[ "$RETENTION_DAYS" -gt 0 ]] && echo "     • Retention: ${RETENTION_DAYS} days"
else
echo "  8. Terraform State Bucket: SKIPPED (CREATE_TFSTATE=0)"
fi
echo
echo "============================================================="
echo "Configuration:"
echo "  Project       : $PROJECT_ID  (#$PROJECT_NUMBER)"
echo "  Repo guard    : $REPO"
echo "  Ref guard     : $BRANCH"
echo "  Provider scope: $PROVIDER_SCOPE"
echo "============================================================="
echo
read -p "Proceed? (y/N) " yn; [[ "${yn:-n}" == "y" ]] || exit 1

echo "==> Enabling APIs"
gcloud services enable iam.googleapis.com iamcredentials.googleapis.com sts.googleapis.com storage.googleapis.com >/dev/null

echo "==> Creating custom role for bucket management"
if ! gcloud iam roles describe "$CUSTOM_ROLE_ID" --project "$PROJECT_ID" &>/dev/null; then
  gcloud iam roles create "$CUSTOM_ROLE_ID" \
    --project "$PROJECT_ID" \
    --title="Bucket Manager" \
    --description="Minimal permissions to manage storage buckets" \
    --permissions="storage.buckets.create,storage.buckets.list,storage.buckets.get,storage.buckets.update,storage.buckets.delete" \
    --stage="GA" >/dev/null
else
  echo "Updating existing custom role with additional permissions"
  gcloud iam roles update "$CUSTOM_ROLE_ID" \
    --project "$PROJECT_ID" \
    --permissions="storage.buckets.create,storage.buckets.list,storage.buckets.get,storage.buckets.update,storage.buckets.delete" >/dev/null || true
fi

echo "==> Ensuring Service Account"
if ! gcloud iam service-accounts describe "$SA_EMAIL" &>/dev/null; then
  gcloud iam service-accounts create "$SA_NAME" \
    --display-name="GitHub Actions deployer (WIF)"
  # Wait for service account to propagate
  sleep 2
fi

echo "==> Granting runtime roles to SA (demo; tighten for prod)"
for role in "${RUNTIME_ROLES[@]}"; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${SA_EMAIL}" --role="$role" >/dev/null || true
done

echo "==> Ensuring Workload Identity Pool"
if ! gcloud iam workload-identity-pools describe "$POOL_ID" --project "$PROJECT_ID" --location global &>/dev/null; then
  gcloud iam workload-identity-pools create "$POOL_ID" \
    --project "$PROJECT_ID" --location global --display-name "GitHub Actions Pool"
fi

echo "==> Ensuring OIDC Provider (GitHub) with attribute mapping + condition"
ATTRIBUTE_MAPPING="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner,attribute.ref=assertion.ref,attribute.workflow=assertion.workflow,attribute.sha=assertion.sha"

# Check if provider exists and is not deleted
PROVIDER_EXISTS=false
if gcloud iam workload-identity-pools providers describe "$PROVIDER_ID" \
  --workload-identity-pool "$POOL_ID" --project "$PROJECT_ID" --location global &>/dev/null; then
  PROVIDER_STATE=$(gcloud iam workload-identity-pools providers describe "$PROVIDER_ID" \
    --workload-identity-pool "$POOL_ID" --project "$PROJECT_ID" --location global --format="value(state)" 2>/dev/null || echo "")
  if [[ "$PROVIDER_STATE" != "DELETED" ]]; then
    PROVIDER_EXISTS=true
  fi
fi

if [[ "$PROVIDER_EXISTS" == "false" ]]; then
  gcloud iam workload-identity-pools providers create-oidc "$PROVIDER_ID" \
    --project "$PROJECT_ID" --location global --workload-identity-pool "$POOL_ID" \
    --display-name "GitHub OIDC" \
    --issuer-uri "https://token.actions.githubusercontent.com" \
    --attribute-mapping "$ATTRIBUTE_MAPPING" \
    --attribute-condition "$PROVIDER_ATTR_COND" || true
else
  gcloud iam workload-identity-pools providers update-oidc "$PROVIDER_ID" \
    --project "$PROJECT_ID" --location global --workload-identity-pool "$POOL_ID" \
    --attribute-mapping "$ATTRIBUTE_MAPPING" \
    --attribute-condition "$PROVIDER_ATTR_COND" >/dev/null || true
fi

echo "==> Binding Workload Identity User (SA) with ${PROVIDER_SCOPE} condition"
gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
  --project "$PROJECT_ID" \
  --role "roles/iam.workloadIdentityUser" \
  --member "${PRINCIPAL_SET}" \
  --condition "expression=${SA_CONDITION},title=GitHubGuard,description=${PROVIDER_SCOPE} lock" >/dev/null || true

echo "==> Granting Workload Identity Pool token creator for access_token generation"
gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
  --project "$PROJECT_ID" \
  --role="roles/iam.serviceAccountTokenCreator" \
  --member="${PRINCIPAL_SET}" \
  --condition=None >/dev/null || true

echo "==> Granting SA self-impersonation for token generation"
gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/iam.serviceAccountTokenCreator" \
  --condition=None >/dev/null || true

if [[ "$CREATE_TFSTATE" == "1" ]]; then
  echo "==> Ensuring Terraform state bucket (versioned, UBLA)"
  if ! gcloud storage buckets describe "gs://${TF_STATE_BUCKET}" &>/dev/null; then
    gcloud storage buckets create "gs://${TF_STATE_BUCKET}" \
      --project "$PROJECT_ID" --location "$STATE_BUCKET_LOCATION" --uniform-bucket-level-access
  fi
  gcloud storage buckets update "gs://${TF_STATE_BUCKET}" --versioning >/dev/null
  if [[ "$RETENTION_DAYS" -gt 0 ]]; then
    SECONDS=$((RETENTION_DAYS*24*3600))
    gcloud storage buckets update "gs://${TF_STATE_BUCKET}" --retention-period="${SECONDS}" >/dev/null || true
  fi
  echo "==> Bucket IAM: SA gets object-level admin for backend state"
  gcloud storage buckets add-iam-policy-binding "gs://${TF_STATE_BUCKET}" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/storage.objectAdmin" >/dev/null || true
fi

echo
echo "==== Outputs (paste into your workflow / repo variables) ===="
echo "workload_identity_provider: ${PROVIDER_RESOURCE}"
echo "service_account:            ${SA_EMAIL}"
echo "project_number:             ${PROJECT_NUMBER}"
[[ "$CREATE_TFSTATE" == "1" ]] && echo "tf_state_bucket:            ${TF_STATE_BUCKET}"
echo
echo "# Repo Variables (GitHub → Settings → Variables):"
echo "#   GCP_PROJECT_ID=${PROJECT_ID}"
echo "#   GCP_PROJECT_NUMBER=${PROJECT_NUMBER}"
[[ "$CREATE_TFSTATE" == "1" ]] && echo "#   TF_STATE_BUCKET=${TF_STATE_BUCKET}"
echo
echo "# For cleanup, save these names:"
echo "RANDOM_SUFFIX=${RANDOM_SUFFIX}"
echo "SA_NAME=${SA_NAME}"
echo "POOL_ID=${POOL_ID}"
echo "PROVIDER_ID=${PROVIDER_ID}"
echo "TF_STATE_BUCKET=${TF_STATE_BUCKET}"
echo "============================================================="
