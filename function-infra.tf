resource "random_string" "storage_suffix" {
  length  = 6
  special = false
  upper   = false
}

resource "time_sleep" "wait_for_function_identity" {
  depends_on      = [azurerm_linux_function_app.waste_scanner]
  create_duration = "30s"
}

resource "azurerm_storage_account" "function_storage" {
  name                     = "stwastescan${random_string.storage_suffix.result}"
  resource_group_name      = azurerm_resource_group.main.name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"

  tags = {
    owner       = var.owner_tag
    costCenter  = var.cost_center_tag
    environment = var.environment
  }
}

resource "azurerm_service_plan" "function_plan" {
  name                = "plan-waste-scanner"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  os_type             = "Linux"
  sku_name            = "Y1"

  tags = {
    owner       = var.owner_tag
    costCenter  = var.cost_center_tag
    environment = var.environment
  }
}


resource "azurerm_linux_function_app" "waste_scanner" {
  name                       = "func-waste-scanner-${random_string.storage_suffix.result}"
  resource_group_name        = azurerm_resource_group.main.name
  location                   = var.location
  storage_account_name       = azurerm_storage_account.function_storage.name
  storage_account_access_key = azurerm_storage_account.function_storage.primary_access_key
  service_plan_id            = azurerm_service_plan.function_plan.id

  site_config {
    application_stack {
      node_version = "22"
    }
  }

  app_settings = {
    "ALERT_EMAIL"              = var.alert_email
    "FUNCTIONS_WORKER_RUNTIME" = "node"
    "SUBSCRIPTION_ID"          = data.azurerm_subscription.current.subscription_id
    "ACS_ENDPOINT"             = "https://${azurerm_communication_service.waste_scanner_comms.name}.communication.azure.com"
    "ACS_SENDER_ADDRESS"       = "DoNotReply@${azurerm_email_communication_service_domain.managed_domain.mail_from_sender_domain}"
  }

  identity {
    type = "SystemAssigned"
  }

  tags = {
    owner       = var.owner_tag
    costCenter  = var.cost_center_tag
    environment = var.environment
  }
}

resource "azurerm_email_communication_service" "waste_scanner_email" {
  name                = "ecs-waste-scanner"
  resource_group_name = azurerm_resource_group.main.name
  data_location       = "United States"
}

resource "azurerm_email_communication_service_domain" "managed_domain" {
  name              = "AzureManagedDomain"
  email_service_id  = azurerm_email_communication_service.waste_scanner_email.id
  domain_management = "AzureManaged"
}

resource "azurerm_communication_service" "waste_scanner_comms" {
  name                = "acs-waste-scanner"
  resource_group_name = azurerm_resource_group.main.name
  data_location       = "United States"

  tags = {
    environment = var.environment
    owner       = var.owner_tag
    costCenter  = var.cost_center_tag
  }
}

resource "azurerm_role_assignment" "function_storage_blob_data_contributor" {
  scope                            = azurerm_storage_account.function_storage.id
  role_definition_name             = "Storage Blob Data Contributor"
  principal_id                     = azurerm_linux_function_app.waste_scanner.identity[0].principal_id
  skip_service_principal_aad_check = true
  depends_on                       = [time_sleep.wait_for_function_identity]
}

resource "azurerm_role_assignment" "function_reader" {
  scope                = data.azurerm_subscription.current.id
  role_definition_name = "Reader"
  principal_id         = azurerm_linux_function_app.waste_scanner.identity[0].principal_id
}

resource "azurerm_role_assignment" "function_email_sender" {
  scope                = azurerm_communication_service.waste_scanner_comms.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_linux_function_app.waste_scanner.identity[0].principal_id
}