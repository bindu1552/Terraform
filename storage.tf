# ==============================================================================
# Resource Groups
#
# Created only when create_resource_groups = true. Otherwise the storage
# accounts are deployed into resource groups that already exist and are looked
# up via the data source below.
# ==============================================================================

resource "azurerm_resource_group" "storage" {
  for_each = var.create_resource_groups ? local.resource_group_locations : {}
  name     = each.key
  location = each.value
  tags     = var.additional_tags
}

data "azurerm_resource_group" "storage" {
  for_each = var.create_resource_groups ? {} : local.resource_group_locations
  name     = each.key
}

locals {
  resource_group_names = var.create_resource_groups ? {
    for k, rg in azurerm_resource_group.storage : k => rg.name
    } : {
    for k, rg in data.azurerm_resource_group.storage : k => rg.name
  }
}

# ==============================================================================
# Storage Accounts
#
# Security posture mirrors the service EV2 storage account definition in
# a sample ARM template.
# ==============================================================================

resource "azurerm_storage_account" "this" {
  for_each = var.storage_accounts

  name                             = each.value.name
  resource_group_name              = local.resource_group_names[each.value.resource_group_name]
  location                         = coalesce(each.value.location, var.location)
  account_tier                     = each.value.account_tier
  account_replication_type         = each.value.account_replication_type
  account_kind                     = each.value.account_kind
  access_tier                      = each.value.access_tier
  min_tls_version                  = each.value.min_tls_version
  public_network_access_enabled    = each.value.public_network_access_enabled
  shared_access_key_enabled        = each.value.shared_access_key_enabled
  allow_nested_items_to_be_public  = each.value.allow_blob_public_access
  cross_tenant_replication_enabled = false

  identity {
    type = "SystemAssigned"
  }

  network_rules {
    default_action = each.value.network_default_action
    bypass         = ["AzureServices"]
  }

  lifecycle {
    ignore_changes  = [public_network_access_enabled]
    prevent_destroy = true
  }

  tags = merge(var.additional_tags, each.value.tags)
}

# ==============================================================================
# Blob Containers
# ==============================================================================

locals {
  storage_containers = merge([
    for sa_key, sa in var.storage_accounts : {
      for container in sa.containers :
      "${sa_key}/${container}" => {
        storage_account_key = sa_key
        container_name      = container
      }
    }
  ]...)
}

resource "azurerm_storage_container" "this" {
  for_each = local.storage_containers

  name                  = each.value.container_name
  storage_account_id    = azurerm_storage_account.this[each.value.storage_account_key].id
  container_access_type = "private"
}
