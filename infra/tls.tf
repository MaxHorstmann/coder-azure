# TLS for Coder: cert-manager gets a Let's Encrypt certificate for
# coder_domain and *.coder_domain via DNS-01 against the Azure DNS zone, and
# Traefik terminates TLS with it (picking up renewals automatically; coderd
# only reads its certificate at startup).

# --- cert-manager identity (workload identity -> Azure DNS) ------------------

resource "azurerm_user_assigned_identity" "cert_manager" {
  name                = "id-cert-manager-${var.name}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags
}

resource "azurerm_federated_identity_credential" "cert_manager" {
  name                = "aks-cert-manager"
  resource_group_name = azurerm_resource_group.main.name
  parent_id           = azurerm_user_assigned_identity.cert_manager.id
  issuer              = azurerm_kubernetes_cluster.main.oidc_issuer_url
  subject             = "system:serviceaccount:cert-manager:cert-manager"
  audience            = ["api://AzureADTokenExchange"]
}

# Lets cert-manager create/delete the _acme-challenge TXT records.
resource "azurerm_role_assignment" "cert_manager_dns" {
  scope                = azurerm_dns_zone.coder.id
  role_definition_name = "DNS Zone Contributor"
  principal_id         = azurerm_user_assigned_identity.cert_manager.principal_id
}

# --- cert-manager --------------------------------------------------------------

resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  namespace        = "cert-manager"
  create_namespace = true
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = var.cert_manager_chart_version

  values = [yamlencode({
    crds = { enabled = true }
    # Opt the controller into AKS workload identity token injection.
    podLabels      = { "azure.workload.identity/use" = "true" }
    serviceAccount = { labels = { "azure.workload.identity/use" = "true" } }
  })]

  depends_on = [azurerm_role_assignment.aks_cluster_admin]
}

# ClusterIssuer + Certificate, as a small local chart so they're applied after
# the cert-manager CRDs exist.
resource "helm_release" "coder_tls" {
  name      = "coder-tls"
  namespace = kubernetes_namespace_v1.coder.metadata[0].name
  chart     = "${path.module}/charts/coder-tls"

  values = [yamlencode({
    acmeServer        = var.letsencrypt_server
    domain            = var.coder_domain
    secretName        = "coder-tls"
    subscriptionID    = var.subscription_id
    resourceGroupName = azurerm_resource_group.main.name
    clientID          = azurerm_user_assigned_identity.cert_manager.client_id
  })]

  depends_on = [
    helm_release.cert_manager,
    azurerm_federated_identity_credential.cert_manager,
    azurerm_role_assignment.cert_manager_dns,
  ]
}

# --- Traefik -------------------------------------------------------------------

resource "helm_release" "traefik" {
  name             = "traefik"
  namespace        = "traefik"
  create_namespace = true
  repository       = "https://traefik.github.io/charts"
  chart            = "traefik"
  version          = var.traefik_chart_version

  values = [yamlencode({
    ingressClass = { enabled = true, isDefaultClass = true, name = "traefik" }

    ports = {
      web = {
        http = {
          redirections = {
            entryPoint = { to = "websecure", scheme = "https", permanent = true }
          }
        }
      }
    }

    service = {
      annotations = {
        # Use the static IP from dns.tf, which the @ and * A records point at.
        "service.beta.kubernetes.io/azure-pip-name"                     = azurerm_public_ip.coder.name
        "service.beta.kubernetes.io/azure-load-balancer-resource-group" = azurerm_resource_group.main.name
      }
    }

    resources = {
      requests = { cpu = "50m", memory = "64Mi" }
      limits   = { memory = "256Mi" }
    }
  })]

  depends_on = [azurerm_role_assignment.aks_network_rg, azurerm_role_assignment.aks_cluster_admin]
}
