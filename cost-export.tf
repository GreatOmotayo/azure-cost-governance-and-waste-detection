resource "azurerm_storage_container" "cost_exports" {
  name                  = "cost-exports"
  storage_account_id    = azurerm_storage_account.function_storage.id
  container_access_type = "private"
}

resource "azurerm_subscription_cost_management_export" "weekly_export" {
  name            = "weekly-cost-export"
  subscription_id = data.azurerm_subscription.current.id
  recurrence_type = "Weekly"

  recurrence_period_start_date = "2026-08-04T00:00:00Z" # first Monday after go-live
  recurrence_period_end_date   = "2027-08-03T00:00:00Z"

  export_data_storage_location {
    container_id = azurerm_storage_container.cost_exports.id
    root_folder_path = "exports"
  }

  export_data_options {
    type       = "ActualCost"
    time_frame = "TheLast7Days"
  }
}