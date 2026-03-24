terraform {
  required_providers {
    cloudflare = {
      source = "cloudflare/cloudflare"
      version = ">= 5.8.2"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.26.0"
    }

    http = {
      source  = "hashicorp/http"
      version = "~> 3.4.0"
    }
  }
  required_version = ">= 1.2"
}


provider "cloudflare" {
  email   = var.cloudflare_email
  api_token = var.cloudflare_token
}
