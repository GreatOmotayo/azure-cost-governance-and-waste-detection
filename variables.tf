variable "location" {
  description = "Azure region for all resource in this lab"
  type        = string
  default     = "centralus"
}

variable "environment" {
  description = "Environment tag value"
  type        = string
  default     = "dev"
}

variable "resource_group_name" {
  description = "Single resource group holding all compute for this lab"
  type        = string
  default     = "rg-cost-governance-waste-detection"
}


variable "owner_tag" {
  description = "Required tag to identifies who owns a resource for cost accountability"
  type        = string
  default     = "omotayo"
}

variable "cost_center_tag" {
  description = "Required tag, groups resources for charegback/showback reporting"
  type        = string
  default     = "engineering"
}

variable "tag_policy_effect" {
  description = "Enforcement level for the tagging policy"
  type        = string
  default     = "Deny"
}

variable "budget_amount" {
  description = "Monthly subscription budget threshold in the billing currency"
  type        = number
  default     = 20
}

variable "alert_email" {
  description = "Email address to receive budget alerts and weekly waste-scanner report"
  type        = string
  # no default, supplied via terraform.tfvars, which is gitignored
}

variable "admin_username" {
  description = "Local admin username for the over-provisioned demo VM"
  type        = string
  default     = "azureadmin"
}