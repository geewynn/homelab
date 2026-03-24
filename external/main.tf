module "cloudflare" {
  source                = "./modules/cloudflare"
  cloudflare_account_id  = var.cloudflare_account_id
  cloudflare_zone  = var.cloudflare_zone
  cloudflare_zone_id =   var.cloudflare_zone_id
  cloudflare_email      = var.cloudflare_email
  cloudflare_token    = var.cloudflare_token
}

