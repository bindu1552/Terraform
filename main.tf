data "azurerm_client_config" "current" {}

locals {
  # Distinct resource groups referenced by the storage accounts, mapped to a
  # location so they can be created when create_resource_groups = true.
  resource_groups = {
    for sa in values(var.storage_accounts) :
    sa.resource_group_name => coalesce(sa.location, var.location)...
  }

  resource_group_locations = {
    for rg_name, locations in local.resource_groups :
    rg_name => locations[0]
  }
}
