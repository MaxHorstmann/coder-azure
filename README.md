# coder-azure
Setting up [Coder](https://coder.com) in Azure, following the [Coder on Kubernetes install guide](https://coder.com/docs/install/server/kubernetes/).

- [`infra/`](infra/): Terraform for the Azure infrastructure (AKS + PostgreSQL Flexible Server). See [infra/README.md](infra/README.md).
- [`.github/workflows/terraform.yml`](.github/workflows/terraform.yml): `terraform plan` on PRs, `terraform apply` on merge to `main`.
