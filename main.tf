resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location

  tags = {
    environment = var.environment
    owner       = var.owner_tag
    costCenter  = var.cost_center_tag
  }
}

data "azurerm_subscription" "current" {}

resource "azurerm_policy_definition" "require_cost_tags" {
  name         = "require-cost-governance-tags"
  policy_type  = "Custom"
  mode         = "Indexed"
  display_name = "Require owner and costCenter tags on resources"
  description  = "Denies (or audits) resource creation/update when the 'owner' or 'costCenter' tag is missing"


  policy_rule = jsonencode({
    if = {
      anyOf = [
        { field = "tags['owner']", exists = "false" },
        { field = "tags['costCenter']", exists = "false" }
      ]
    }
    then = {
      effect = "[parameters('effect')]"
    }
  })

  parameters = jsonencode({
    effect = {
      type = "String"
      metadata = {
        displayName = "Effect"
        description = "Enable or disable execution of the policy"
      }
      allowedValues = ["Deny", "Audit", "Disabled"]
      defaultValue  = "Deny"
    }
  })
}

resource "azurerm_subscription_policy_assignment" "require_cost_tags" {
  name                 = "require-cost-governance-tags"
  policy_definition_id = azurerm_policy_definition.require_cost_tags.id
  subscription_id      = data.azurerm_subscription.current.id
  display_name         = "Require owner and costCenter tags (subscription scope)"
  description          = "Enforces the cost-governance tagging strategy across the whole subscription"

  parameters = jsonencode({
    effect = { value = var.tag_policy_effect }
  })
}
# Trigger build
