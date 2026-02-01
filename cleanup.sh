#!/usr/bin/env bash
set -euo pipefail

# Usage: cleanup.sh <project-id> [sa-name] [pool-id] [provider-id] [bucket-name]
PROJECT_ID="${1:?Usage: $0 <project-id> [sa-name] [pool-id] [provider-id] [bucket-name]}"
SA_NAME="${2:-${SA_NAME:-gha-deployer}}"
POOL_ID="${3:-${POOL_ID:-gh-pool}}"
PROVIDER_ID="${4:-${PROVIDER_ID:-github}}"
TF_STATE_BUCKET="${5:-${TF_STATE_BUCKET}}"
CUSTOM_ROLE_ID="${6:-bucketCreator}"

echo "Cleaning up resources:"
echo "  Project: $PROJECT_ID"
echo "  Service Account: $SA_NAME"
echo "  Pool ID: $POOL_ID"
echo "  Provider ID: $PROVIDER_ID"
echo "  Bucket: ${TF_STATE_BUCKET:-auto-detect}"
echo

gcloud config set project "$PROJECT_ID" >/dev/null
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

echo "==> Delete provider & pool"
# Check if provider exists and delete it
if gcloud iam workload-identity-pools providers describe "$PROVIDER_ID" \
  --workload-identity-pool "$POOL_ID" --location global &>/dev/null; then
  gcloud iam workload-identity-pools providers delete "$PROVIDER_ID" \
    --workload-identity-pool "$POOL_ID" --location global --quiet || true
fi

# Check if pool exists and delete it
if gcloud iam workload-identity-pools describe "$POOL_ID" --location global &>/dev/null; then
  gcloud iam workload-identity-pools delete "$POOL_ID" --location global --quiet || true
fi

echo "==> Delete Terraform state bucket"
if [[ -z "${TF_STATE_BUCKET:-}" ]]; then
  echo "No bucket name provided, skipping bucket deletion"
else
  if gcloud storage buckets describe "gs://${TF_STATE_BUCKET}" &>/dev/null; then
    echo "Removing all objects from bucket..."
    gcloud storage rm -r "gs://${TF_STATE_BUCKET}/**" &>/dev/null || true
    echo "Deleting bucket: gs://${TF_STATE_BUCKET}"
    gcloud storage buckets delete "gs://${TF_STATE_BUCKET}" --quiet || true
  else
    echo "Bucket not found: gs://${TF_STATE_BUCKET}"
  fi
fi

echo "==> Removing service account IAM bindings first"
# Remove service account-level IAM bindings BEFORE deleting the service account
PRINCIPAL_SET="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}/*"
gcloud iam service-accounts remove-iam-policy-binding "$SA_EMAIL" \
  --role="roles/iam.serviceAccountTokenCreator" \
  --member="${PRINCIPAL_SET}" --quiet &>/dev/null || true

gcloud iam service-accounts remove-iam-policy-binding "$SA_EMAIL" \
  --role="roles/iam.serviceAccountTokenCreator" \
  --member="serviceAccount:${SA_EMAIL}" --quiet &>/dev/null || true

# Remove project-level IAM bindings
for role in "roles/storage.objectViewer" "projects/${PROJECT_ID}/roles/${CUSTOM_ROLE_ID}" "roles/iam.serviceAccountTokenCreator"; do
  gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${SA_EMAIL}" --role="$role" --quiet &>/dev/null || true
done

echo "==> Deleting custom role"
gcloud iam roles delete "${CUSTOM_ROLE_ID}" --project "$PROJECT_ID" --quiet &>/dev/null || true

echo "==> Delete service account"
if gcloud iam service-accounts describe "$SA_EMAIL" &>/dev/null; then
  gcloud iam service-accounts delete "$SA_EMAIL" --quiet || true
  echo "Service account deleted: $SA_EMAIL"
else
  echo "Service account not found: $SA_EMAIL"
fi

echo
echo "==> Verifying cleanup..."
echo -n "Service Account: "
if gcloud iam service-accounts describe "$SA_EMAIL" &>/dev/null; then
  echo "STILL EXISTS"
else
  echo "DELETED"
fi

echo -n "Terraform State Bucket: "
if [[ -z "${TF_STATE_BUCKET:-}" ]]; then
  echo "SKIPPED"
else
  if gcloud storage buckets describe "gs://${TF_STATE_BUCKET}" &>/dev/null; then
    echo "STILL EXISTS"
  else
    echo "DELETED"
  fi
fi

echo -n "Workload Identity Provider: "
if gcloud iam workload-identity-pools providers describe "$PROVIDER_ID" \
  --workload-identity-pool "$POOL_ID" --location global &>/dev/null; then
  PROVIDER_STATE=$(gcloud iam workload-identity-pools providers describe "$PROVIDER_ID" \
    --workload-identity-pool "$POOL_ID" --location global --format="value(state)" 2>/dev/null || echo "UNKNOWN")
  echo "EXISTS (state: $PROVIDER_STATE)"
else
  echo "DELETED"
fi

echo -n "Workload Identity Pool: "
if gcloud iam workload-identity-pools describe "$POOL_ID" --location global &>/dev/null; then
  POOL_STATE=$(gcloud iam workload-identity-pools describe "$POOL_ID" --location global --format="value(state)" 2>/dev/null || echo "UNKNOWN")
  echo "EXISTS (state: $POOL_STATE)"
else
  echo "DELETED"
fi

echo "Cleanup complete."
