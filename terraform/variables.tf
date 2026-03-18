variable "resource_group_name" { type = string }
variable "api_management_name" { type = string }
variable "fail_if_no_specs" {
  type    = bool
  default = true
}

variable "attach_api_policy" {
  type    = bool
  default = true
}
variable "spec_folder" {
  description = "Folder containing bundled OpenAPI spec files."
  type        = string
  default     = "../build/api-bundled"
}

variable "subscription_required" {
  description = "Whether APIM subscription key is required at the API level."
  type        = bool
  default     = true
}

variable "subscription_key_header_name" {
  description = "Header name for API-level subscription key."
  type        = string
  default     = "subscriptionKey"
}

variable "subscription_key_query_param_name" {
  description = "Query parameter name for API-level subscription key."
  type        = string
  default     = "subscriptionKey"
}
