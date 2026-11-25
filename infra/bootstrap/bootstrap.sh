#!/usr/bin/env bash
#
# One-time bootstrap for the Terraform pipeline. Creates:
#   - a resource group + storage account + container for Terraform state
#   - an Entra ID app registration / service principal for GitHub Actions,
#     with OIDC federated credentials (no client secrets)
#   - role assignments for that principal
#   - the GitHub repo variables and `production` environment the workflow uses
#
# Safe to re-run. Requires: az (logged in), gh (logged in), jq.
#
# Usage:
#   ./infra/bootstrap/bootstrap.sh
#
# Override defaults with env vars, e.g.:
#   LOCATION=westeurope STATE_STORAGE_ACCOUNT=sttfstatefoo ./infra/bootstrap/bootstrap.sh

set -euo pipefail

SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-$(az account show --query id -o tsv)}"
TENANT_ID="$(az account show --subscription "$SUBSCRIPTION_ID" --query tenantId -o tsv)"
LOCATION="${LOCATION:-eastus2}"
GITHUB_REPO="${GITHUB_REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"

STATE_RESOURCE_GROUP="${STATE_RESOURCE_GROUP:-rg-coder-tfstate}"
# Storage account names are globally unique, 3-24 lowercase alphanumerics.
STATE_STORAGE_ACCOUNT="${STATE_STORAGE_ACCOUNT:-sttfstate$(echo -n "$SUBSCRIPTION_ID" | shasum | cut -c1-8)}"
STATE_CONTAINER="${STATE_CONTAINER:-tfstate}"

APP_NAME="${APP_NAME:-github-${GITHUB_REPO//\//-}-terraform}"
ENVIRONMENT="${ENVIRONMENT:-production}"

echo "Subscription:     $SUBSCRIPTION_ID"
echo "Tenant:           $TENANT_ID"
echo "GitHub repo:      $GITHUB_REPO"
echo "State storage:    $STATE_RESOURCE_GROUP / $STATE_STORAGE_ACCOUNT / $STATE_CONTAINER"
echo "App registration: $APP_NAME"
echo
read -r -p "Continue? [y/N] " ok
[[ "$ok" =~ ^[Yy]$ ]] || exit 1

az account set --subscription "$SUBSCRIPTION_ID"

echo "==> Registering resource providers"
for ns in Microsoft.ContainerService Microsoft.DBforPostgreSQL Microsoft.Network \
          Microsoft.OperationalInsights Microsoft.OperationsManagement Microsoft.Insights \
          Microsoft.ManagedIdentity Microsoft.Storage Microsoft.Compute; do
  az provider register --namespace "$ns" --output none
done

echo "==> Creating Terraform state storage"
az group create --name "$STATE_RESOURCE_GROUP" --location "$LOCATION" \
  --tags project=coder managed-by=bootstrap --output none

if ! az storage account show --name "$STATE_STORAGE_ACCOUNT" --resource-group "$STATE_RESOURCE_GROUP" &>/dev/null; then
  az storage account create \
    --name "$STATE_STORAGE_ACCOUNT" \
    --resource-group "$STATE_RESOURCE_GROUP" \
    --location "$LOCATION" \
    --sku Standard_ZRS \
    --kind StorageV2 \
    --min-tls-version TLS1_2 \
    --allow-blob-public-access false \
    --allow-shared-key-access false \
    --output none
fi
STORAGE_ID="$(az storage account show --name "$STATE_STORAGE_ACCOUNT" --resource-group "$STATE_RESOURCE_GROUP" --query id -o tsv)"

az storage account blob-service-properties update \
  --account-name "$STATE_STORAGE_ACCOUNT" \
  --resource-group "$STATE_RESOURCE_GROUP" \
  --enable-versioning true \
  --enable-delete-retention true --delete-retention-days 30 \
  --output none

# Management-plane create, so no data-plane role is needed for the caller.
az storage container-rm create \
  --storage-account "$STATE_STORAGE_ACCOUNT" \
  --resource-group "$STATE_RESOURCE_GROUP" \
  --name "$STATE_CONTAINER" \
  --output none 2>/dev/null || true

echo "==> Creating app registration + service principal"
APP_ID="$(az ad app list --display-name "$APP_NAME" --query '[0].appId' -o tsv)"
if [[ -z "$APP_ID" ]]; then
  APP_ID="$(az ad app create --display-name "$APP_NAME" --query appId -o tsv)"
fi
APP_OBJECT_ID="$(az ad app show --id "$APP_ID" --query id -o tsv)"
SP_OBJECT_ID="$(az ad sp show --id "$APP_ID" --query id -o tsv 2>/dev/null || az ad sp create --id "$APP_ID" --query id -o tsv)"

echo "==> Adding federated credentials"
add_fic() {
  local name="$1" subject="$2"
  if ! az ad app federated-credential show --id "$APP_OBJECT_ID" --federated-credential-id "$name" &>/dev/null; then
    az ad app federated-credential create --id "$APP_OBJECT_ID" --parameters "$(jq -n \
      --arg name "$name" --arg subject "$subject" \
      '{name: $name, issuer: "https://token.actions.githubusercontent.com", subject: $subject, audiences: ["api://AzureADTokenExchange"]}')" \
      --output none
  fi
}
add_fic "github-pull-request" "repo:${GITHUB_REPO}:pull_request"
add_fic "github-env-${ENVIRONMENT}" "repo:${GITHUB_REPO}:environment:${ENVIRONMENT}"

echo "==> Assigning roles"
assign() {
  local role="$1" scope="$2"
  az role assignment create --assignee-object-id "$SP_OBJECT_ID" --assignee-principal-type ServicePrincipal \
    --role "$role" --scope "$scope" --output none
}
# Contributor to create resources; RBAC Administrator because Terraform creates
# role assignments (AKS identity -> VNet, cluster-admin on AKS).
assign "Contributor" "/subscriptions/$SUBSCRIPTION_ID"
assign "Role Based Access Control Administrator" "/subscriptions/$SUBSCRIPTION_ID"
# Data-plane access to the state blobs (shared keys are disabled).
assign "Storage Blob Data Contributor" "$STORAGE_ID"

echo "==> Configuring GitHub repo variables and environment"
gh variable set AZURE_CLIENT_ID         --repo "$GITHUB_REPO" --body "$APP_ID"
gh variable set AZURE_TENANT_ID         --repo "$GITHUB_REPO" --body "$TENANT_ID"
gh variable set AZURE_SUBSCRIPTION_ID   --repo "$GITHUB_REPO" --body "$SUBSCRIPTION_ID"
gh variable set TFSTATE_RESOURCE_GROUP  --repo "$GITHUB_REPO" --body "$STATE_RESOURCE_GROUP"
gh variable set TFSTATE_STORAGE_ACCOUNT --repo "$GITHUB_REPO" --body "$STATE_STORAGE_ACCOUNT"
gh variable set TFSTATE_CONTAINER       --repo "$GITHUB_REPO" --body "$STATE_CONTAINER"
gh api --method PUT "repos/${GITHUB_REPO}/environments/${ENVIRONMENT}" --silent

echo
echo "Done. Local usage:"
echo "  cd infra"
echo "  terraform init \\"
echo "    -backend-config=resource_group_name=$STATE_RESOURCE_GROUP \\"
echo "    -backend-config=storage_account_name=$STATE_STORAGE_ACCOUNT \\"
echo "    -backend-config=container_name=$STATE_CONTAINER \\"
echo "    -backend-config=key=coder.tfstate"
echo "  terraform plan -var subscription_id=$SUBSCRIPTION_ID"
echo
echo "Note: local runs need 'Storage Blob Data Contributor' on $STATE_STORAGE_ACCOUNT for your own user."
