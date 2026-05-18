terraform {
  required_version = "~> 1"

  required_providers {
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4"
    }
    cloudinit = {
      source  = "hashicorp/cloudinit"
      version = "~> 2"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.13"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4"
    }
  }
}

provider "azuread" {

}

provider "azurerm" {
  storage_use_azuread = true
  features {}
}