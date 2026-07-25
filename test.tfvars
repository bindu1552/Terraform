# ==============================================================================
# Test environment
# Source: the sample EV2 config
# ==============================================================================

subscription_id = "<TEST_SUBSCRIPTION_ID>" # Test
tenant_id       = "<TENANT_ID>"

environment = "Test"
location    = "westus"

# Use existing resource group(s) referenced below (do not create them).
create_resource_groups = false

additional_tags = {
  service     = "the storage service"
  environment = "test"
  creator     = "tf"
}

storage_accounts = {
  # blobStorage (sample config)
  blob = {
    name                = "tftestblobstore"
    resource_group_name = "tfstate-rg"
    location            = "westus"
    account_kind        = "StorageV2"
    tags = {
      Env = "Test1"
    }
  }

  # Automation storage (sample config)
  automation = {
    name                     = "tftestautomation"
    resource_group_name      = "tfstate-rg"
    location                 = "westus"
    account_tier             = "Standard"
    account_replication_type = "RAGRS"
    account_kind             = "StorageV2"
    access_tier              = "Hot"
    tags = {
      env = "test"
    }
  }
}
