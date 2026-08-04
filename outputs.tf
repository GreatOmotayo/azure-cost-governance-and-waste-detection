output "resource_group_name" {
  description = "The name of the resource group holding this project"
  value       = azurerm_resource_group.main.name
}

output "function_app_name" {
  description = "The name of the deployed waste scanner function app / report-builder function app"
  value       = azurerm_linux_function_app.waste_scanner.name
}

output "function_app_default_hostname" {
  description = "The default hostname of the deployed waste scanner function app / report-builder function app"
  value       = azurerm_linux_function_app.waste_scanner.default_hostname
}

output "storage_account_name" {
  description = "Storage account backing the function app, cost exports and reports"
  value       = azurerm_storage_account.function_storage.name
}

output "cost_exports_container" {
  description = "Container where Cost Management drops weekly CSV exports"
  value       = azurerm_storage_container.cost_exports.name
}

output "budget_name" {
  description = "The name of the subscription budget enforcing the spend threshold"
  value       = azurerm_consumption_budget_subscription.monthly_budget.name
}

output "tagging_policy_assignment_id" {
  description = "The ID of the subscription-level policy assignment enforcing the cost-governance tagging strategy"
  value       = azurerm_subscription_policy_assignment.require_cost_tags.id
}

output "communication_service_name" {
  description = "The name of the Azure Communication Service used to send report-ready emails"
  value       = azurerm_communication_service.waste_scanner_comms.name
}

output "function_identity_principal_id" {
  description = "The principal ID of the system-assigned managed identity for the function app"
  value       = azurerm_linux_function_app.waste_scanner.identity[0].principal_id
} # Trigger pipeline
