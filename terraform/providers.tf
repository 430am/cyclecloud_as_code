terraform {
  required_version = "~> 1.15"

  required_providers {
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.8"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.73"
    }
    cloudinit = {
      source  = "hashicorp/cloudinit"
      version = "~> 2.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.14"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.3"
    }
  }
}

provider "azuread" {

}

provider "azurerm" {
  storage_use_azuread = true
  features {}
}