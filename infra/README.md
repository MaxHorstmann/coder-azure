# infra

Terraform for the Azure infrastructure that will host [Coder](https://coder.com/docs/install/server/kubernetes/):

| File          | What                                                                                   |
|---------------|----------------------------------------------------------------------------------------|
| `main.tf`     | Resource group                                                                         |
| `network.tf`  | VNet with an AKS subnet and a subnet delegated to Postgres; private DNS zone for Postgres |
| `aks.tf`      | Minimal AKS cluster (Free tier, one autoscaling 1-3 node pool of `Standard_D2s_v5`; Azure CNI overlay + Cilium, Entra ID + Azure RBAC, workload identity) |
| `postgres.tf` | PostgreSQL Flexible Server (private VNet access only) and a `coder` database           |
| `coder.tf`    | `coder` namespace, `coder-db-url` secret and the Coder Helm release (steps 1, 3 and 4 of the [Coder Kubernetes install](https://coder.com/docs/install/server/kubernetes/)) |
| `tls.tf`      | cert-manager (workload identity → Azure DNS), Let's Encrypt wildcard cert via `charts/coder-tls`, Traefik ingress on the static IP |
| `dns.tf`      | Azure DNS zone for `coder_domain` (delegated from the registrar), static public IP for Coder, `@` and `*` A records |
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

Your user needs `Storage Blob Data Contributor` on the state storage account, plus
`Azure Kubernetes Service RBAC Cluster Admin` on the cluster and [`kubelogin`](https://azure.github.io/kubelogin/)
installed (`brew install Azure/kubelogin/kubelogin`), since Terraform also manages Kubernetes resources.

## Accessing the cluster

Local accounts are disabled; access is via Entra ID. Pass group object IDs in `aks_admin_group_object_ids`
to grant cluster-admin, then:

```sh
az aks get-credentials -g rg-coder-centralus -n aks-coder
kubelogin convert-kubeconfig -l azurecli
kubectl get nodes
```

## DNS for Coder

`coder.maxhorstmann.net` is delegated from Namecheap (where `maxhorstmann.net` lives) to the Azure DNS zone in
`dns.tf`. After the zone is created, add one `NS` record per name server at the registrar:

```sh
terraform output coder_dns_name_servers
```

In Namecheap → Domain List → maxhorstmann.net → Advanced DNS, add an `NS Record` with host `coder` for each
value. Check delegation with `dig NS coder.maxhorstmann.net +short`.

## Coder

Coder runs at **https://coder.maxhorstmann.net** (`terraform output coder_access_url`), installed by Terraform
following the [Coder Kubernetes install guide](https://coder.com/docs/install/server/kubernetes/):

```
Internet ─▶ static IP (pip-coder) ─▶ Traefik (TLS, HTTP→HTTPS) ─▶ coder (ClusterIP) ─▶ Postgres (private)
                                          ▲
                cert-manager ── DNS-01 ──▶ Azure DNS zone coder.maxhorstmann.net
```

- **Database**: `CODER_PG_CONNECTION_URL` comes from the `coder-db-url` secret (key `url`), pointing at the managed
  Postgres server (`sslmode=require`).
- **TLS**: cert-manager gets a Let's Encrypt cert for `coder.maxhorstmann.net` and `*.coder.maxhorstmann.net`
  (secret `coder/coder-tls`) using DNS-01. It authenticates to Azure DNS with workload identity
  (`id-cert-manager-coder`, *DNS Zone Contributor* on the zone), so there are no secrets. Traefik terminates TLS and
  reloads renewed certs automatically. coderd itself only reads certificates at startup, which is why it doesn't
  terminate TLS.
- **Workspace apps**: `CODER_WILDCARD_ACCESS_URL=*.coder.maxhorstmann.net`.
- **Versions**: `coder_chart_version`, `cert_manager_chart_version`, `traefik_chart_version`.

Open the URL and create the first (admin) user to finish setup. Check certificate status with
`kubectl -n coder get certificate coder`.
