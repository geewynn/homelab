data "cloudflare_zone" "zone" {
  filter = {
    name = var.cloudflare_zone
  }
}


resource "random_password" "tunnel_secret" {
  length  = 64
  special = false
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "homelab" {
  account_id    = var.cloudflare_account_id
  name          = "homelab"
  config_src    = "local"
  tunnel_secret = base64encode(random_password.tunnel_secret.result)
}

data "cloudflare_zero_trust_tunnel_cloudflared_token" "homelab" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.homelab.id
}


resource "cloudflare_dns_record" "tunnel_wildcard" {
  zone_id = var.cloudflare_zone_id
  name    = "*"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.homelab.id}.cfargotunnel.com"
  type    = "CNAME"
  ttl     = 1
  proxied = true
}

resource "kubernetes_namespace" "cloudflared" {
  metadata {
    name = "cloudflared"
  }
}

resource "kubernetes_secret" "cloudflared_tunnel_token" {
  metadata {
    name      = "cloudflared-tunnel-token"
    namespace = kubernetes_namespace.cloudflared.metadata[0].name
  }

  data = {
    "token" = data.cloudflare_zero_trust_tunnel_cloudflared_token.homelab.token
  }
}