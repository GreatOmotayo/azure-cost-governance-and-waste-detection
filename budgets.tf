resource "azurerm_monitor_action_group" "cost_alerts" {
  name                = "ag-cost-governance-alerts"
  resource_group_name = azurerm_resource_group.main.name
  short_name          = "costalerts"

  email_receiver {
    name                    = "primary-email"
    email_address           = var.alert_email
    use_common_alert_schema = true
  }

  tags = {
    environment = var.environment
    owner       = var.owner_tag
    costCenter  = var.cost_center_tag
  }
}

resource "azurerm_consumption_budget_subscription" "monthly_budget" {
  name            = "budget-cost-governance"
  subscription_id = "/subscriptions/${data.azurerm_subscription.current.subscription_id}"

  amount     = var.budget_amount
  time_grain = "Monthly"

  time_period {
    start_date = formatdate("YYYY-MM-01'T'00:00:00Z", timestamp())
  }

  notification {
    enabled        = true
    threshold      = 50
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = [var.alert_email]

    contact_groups = [
      azurerm_monitor_action_group.cost_alerts.id
    ]

  }

  notification {
    enabled        = true
    threshold      = 90
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = [var.alert_email]

    contact_groups = [
      azurerm_monitor_action_group.cost_alerts.id
    ]

  }

  lifecycle {
    ignore_changes = [time_period]
  }

}

