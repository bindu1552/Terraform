# ==============================================================================
# Prod environment
# Source: the sample EV2 config
# ==============================================================================

subscription_id = "<PROD_SUBSCRIPTION_ID>" # Prod
tenant_id       = "<TENANT_ID>"

environment = "Prod"
location    = "westus"

# Set to true only if the resource groups below do not yet exist.
create_resource_groups = false

additional_tags = {
  service     = "the storage service"
  environment = "prod"
  creator     = "tf"
}

storage_accounts = {
  # blobStorage (sample config)
  blob = {
    name                     = "tfprodblobstore"
    resource_group_name      = "prod-rg"
    location                 = "westus"
    account_tier             = "Standard"
    account_replication_type = "RAGRS"
    account_kind             = "StorageV2"
    access_tier              = "Hot"
  }
}
