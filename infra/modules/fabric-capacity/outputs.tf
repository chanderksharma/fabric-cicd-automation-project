output "id" {
  description = "ARM resource ID of the Fabric capacity."
  value       = azurerm_fabric_capacity.this.id
}

output "name" {
  description = "Normalised capacity name as it appears in Azure and in the Fabric admin portal."
  value       = azurerm_fabric_capacity.this.name
}

output "sku" {
  description = "SKU the capacity was provisioned with."
  value       = var.sku
}

output "location" {
  description = "Region the capacity was provisioned in."
  value       = azurerm_fabric_capacity.this.location
}
