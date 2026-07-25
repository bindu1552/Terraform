output "subscription_id" {
  description = "Subscription the storage accounts were deployed into."
  value       = data.azurerm_client_config.current.subscription_id
}

output "storage_account_ids" {
  description = "Resource ids of the created storage accounts, keyed by logical name."
  value       = { for k, sa in azurerm_storage_account.this : k => sa.id }
}

output "storage_account_names" {
  description = "Names of the created storage accounts, keyed by logical name."
  value       = { for k, sa in azurerm_storage_account.this : k => sa.name }
}

output "storage_account_principal_ids" {
  description = "System-assigned managed identity principal ids of the storage accounts."
  value       = { for k, sa in azurerm_storage_account.this : k => sa.identity[0].principal_id }
}

output "storage_container_ids" {
  description = "Resource ids of the created blob containers."
  value       = { for k, c in azurerm_storage_container.this : k => c.id }
}
