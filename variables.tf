# ==============================================================================
# Subscription / Tenant Configuration
#
# Values are sourced from the service EV2 config
# (the sample EV2 config):
#   Test : subscription <TEST_SUBSCRIPTION_ID> (Test)
#          tenant       <TENANT_ID>
#   Prod : subscription <PROD_SUBSCRIPTION_ID> (Prod)
#          tenant       <TENANT_ID>
# ==============================================================================

variable "subscription_id" {
  type        = string
  description = "Azure subscription id the storage accounts are deployed into."
}

variable "tenant_id" {
  type        = string
  description = "Azure AD tenant id for the target subscription."
}

# ==============================================================================
# General Configuration
# ==============================================================================

variable "environment" {
  type        = string
  description = "The deployment environment name (Test, Prod)."
}

variable "location" {
  type        = string
  description = "Default Azure region for created resources."
  default     = "westus"
}

variable "create_resource_groups" {
  type        = bool
  description = "When true, resource groups referenced by the storage accounts are created. Set to false to deploy into pre-existing resource groups."
  default     = false
}

variable "additional_tags" {
  type        = map(string)
  description = "Additional resource tags applied to every resource."
  default     = {}
}

# ==============================================================================
# Storage Account Configuration
#
# One entry per storage account used by the service. Defaults mirror the
# hardened settings from a sample ARM template
# (StorageV2, TLS1_2, no public blob / shared-key access, network deny with
# AzureServices bypass, public network disabled).
# ==============================================================================

variable "storage_accounts" {
  description = "Map of storage accounts to create, keyed by a logical name."
  type = map(object({
    name                          = string
    resource_group_name           = string
    location                      = optional(string)
    account_tier                  = optional(string, "Standard")
    account_replication_type      = optional(string, "RAGRS")
    account_kind                  = optional(string, "StorageV2")
    access_tier                   = optional(string, "Hot")
    min_tls_version               = optional(string, "TLS1_2")
    public_network_access_enabled = optional(bool, false)
    shared_access_key_enabled     = optional(bool, false)
    allow_blob_public_access      = optional(bool, false)
    network_default_action        = optional(string, "Deny")
    containers                    = optional(list(string), [])
    tags                          = optional(map(string), {})
  }))
  default = {}
}
