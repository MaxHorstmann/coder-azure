# infra

Terraform for the Azure infrastructure that will host [Coder](https://coder.com/docs/install/server/kubernetes/):

| File          | What                                                                                   |
|---------------|----------------------------------------------------------------------------------------|
| `main.tf`     | Resource group, Log Analytics workspace                                                |
| `network.tf`  | VNet with an AKS subnet and a subnet delegated to Postgres; private DNS zone for Postgres |
| `aks.tf`      | AKS cluster (Azure CNI overlay + Cilium, Entra ID + Azure RBAC, workload identity), system + autoscaling user node pool |
| `postgres.tf` | PostgreSQL Flexible Server (private VNet access only) and a `coder` database           |
| `outputs.tf`  | Cluster name, OIDC issuer, Postgres FQDN, and a sensitive `coder_pg_connection_url`    |

```
            VNet 10.10.0.0/16
 ┌──────────────────────────────────────────┐
 │ snet-aks 10.10.0.0/20    snet-postgres    │
 │ ┌──────────────────┐     10.10.16.0/24    │
 │ │ AKS nodes        │────▶┌─────────────┐  │
 │ │ (pods: overlay   │     │ PG Flexible │  │
 │ │  192.168.0.0/16) │     │ Server      │  │
 │ └──────────────────┘     └─────────────┘  │
 └──────────────────────────────────────────┘
          private DNS: <name>.private.postgres.database.azure.com
```

## One-time setup

Run the bootstrap script once (needs `az`, `gh`, `jq`, and Owner / User Access Administrator on the subscription):

```sh
az login
./infra/bootstrap/bootstrap.sh
```

It creates:

- A state resource group + storage account (ZRS, versioning, soft delete, shared keys disabled) and `tfstate` container.
- An Entra ID app registration for GitHub Actions with OIDC federated credentials for
  `<prefix>:pull_request` (plan) and `<prefix>:ref:refs/heads/main` (apply), where `<prefix>` is read from
  GitHub (e.g. `repo:Owner@123/repo@456` when immutable subjects are on). No secrets.
- Role assignments for that principal: `Contributor` and `Role Based Access Control Administrator` on the
  subscription (Terraform creates role assignments), `Storage Blob Data Contributor` on the state account.
- GitHub repo variables `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `TFSTATE_RESOURCE_GROUP`,
  `TFSTATE_STORAGE_ACCOUNT`, `TFSTATE_CONTAINER`.

> The `Role Based Access Control Administrator` assignment is broad. Consider tightening it with an
> [ABAC condition](https://learn.microsoft.com/azure/role-based-access-control/delegate-role-assignments-overview)
> limiting which roles it can assign, or scoping both roles to a pre-created resource group.

## CI/CD

`.github/workflows/terraform.yml` (a single `terraform` job):

- **Pull requests** touching `infra/**`: `fmt -check`, `init`, `validate`, `plan`, and the plan is posted via [`borchero/terraform-plan-comment`](https://github.com/borchero/terraform-plan-comment)
  (and updated) as a PR comment.
- **Push to `main`**: the same steps, then `apply` of the saved plan.

All runs share one concurrency group so they never contend for the state lock.

## Running locally

```sh
cd infra
terraform init \
  -backend-config=resource_group_name=rg-coder-tfstate \
  -backend-config=storage_account_name=<state account> \
  -backend-config=container_name=tfstate \
  -backend-config=key=coder.tfstate
terraform plan -var subscription_id=$(az account show --query id -o tsv)
```

Your user needs `Storage Blob Data Contributor` on the state storage account.

## Accessing the cluster

Local accounts are disabled; access is via Entra ID. Pass group object IDs in `aks_admin_group_object_ids`
to grant cluster-admin, then:

```sh
az aks get-credentials -g rg-coder -n aks-coder
kubelogin convert-kubeconfig -l azurecli
kubectl get nodes
```

## Next: Coder

The database connection string for Coder's `CODER_PG_CONNECTION_URL` is available as:

```sh
terraform output -raw coder_pg_connection_url
```

Postgres is only reachable from inside the VNet, so this works from AKS pods but not from your laptop.
