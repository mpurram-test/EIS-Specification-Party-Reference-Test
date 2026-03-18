# Look up APIM for IDs
data "azurerm_api_management" "apim" {
  name                = var.api_management_name
  resource_group_name = var.resource_group_name
}

locals {
  spec_folder_path = abspath("${path.root}/${var.spec_folder}")
  api_files        = fileset(local.spec_folder_path, "*.y*ml")

  parsed = [
    for relpath in local.api_files : {
      original_file       = relpath
      display_name        = try(yamldecode(file("${local.spec_folder_path}/${relpath}")).info.title, "Untitled API")
      description         = try(yamldecode(file("${local.spec_folder_path}/${relpath}")).info.description, "")
      api_path            = try(yamldecode(file("${local.spec_folder_path}/${relpath}")).info["x-apim-url-suffix"], try(yamldecode(file("${local.spec_folder_path}/${relpath}")).info["x-apimURLsuffix"], ""))
      version_str         = try(yamldecode(file("${local.spec_folder_path}/${relpath}")).info["x-apim-api-version"], try(yamldecode(file("${local.spec_folder_path}/${relpath}")).info["x-apimURLversion"], ""))
      dynamic_backend_url = "${trim(try(yamldecode(file("${local.spec_folder_path}/${relpath}")).info["x-apim-service-url"], try(yamldecode(file("${local.spec_folder_path}/${relpath}")).info["x-apimServiceURL"], "")), "/")}/${try(yamldecode(file("${local.spec_folder_path}/${relpath}")).info["x-apim-url-suffix"], try(yamldecode(file("${local.spec_folder_path}/${relpath}")).info["x-apimURLsuffix"], ""))}/${try(yamldecode(file("${local.spec_folder_path}/${relpath}")).info["x-apim-api-version"], try(yamldecode(file("${local.spec_folder_path}/${relpath}")).info["x-apimURLversion"], ""))}"
      version_key         = "${try(yamldecode(file("${local.spec_folder_path}/${relpath}")).info["x-apim-url-suffix"], try(yamldecode(file("${local.spec_folder_path}/${relpath}")).info["x-apimURLsuffix"], relpath))}-${try(yamldecode(file("${local.spec_folder_path}/${relpath}")).info["x-apim-api-version"], try(yamldecode(file("${local.spec_folder_path}/${relpath}")).info["x-apimURLversion"], ""))}"
      tags = try(
        can(tolist(yamldecode(file("${local.spec_folder_path}/${relpath}")).info["x-tags"]))
        ? [for t in tolist(yamldecode(file("${local.spec_folder_path}/${relpath}")).info["x-tags"]) : trimspace(tostring(t)) if trimspace(tostring(t)) != ""]
        : [for t in split(",", tostring(yamldecode(file("${local.spec_folder_path}/${relpath}")).info["x-tags"])) : trimspace(t) if trimspace(t) != ""],
        try([for t in yamldecode(file("${local.spec_folder_path}/${relpath}")).tags : t.name], [])
      )
    }
    if try(yamldecode(file("${local.spec_folder_path}/${relpath}")).info["x-apim-url-suffix"], try(yamldecode(file("${local.spec_folder_path}/${relpath}")).info["x-apimURLsuffix"], "")) != ""
  ]

  apis_by_path = { for a in local.parsed : a.api_path => a... }

  families = {
    for path, list in local.apis_by_path : path => {
      display_name = list[0].display_name
      versions = {
        for item in list : item.version_key => {
          version_str         = item.version_str
          original_file       = item.original_file
          description         = item.description
          dynamic_backend_url = item.dynamic_backend_url
          tags                = item.tags
        }
      }
    }
  }
}

resource "null_resource" "ensure_specs" {
  count = var.fail_if_no_specs ? 1 : 0

  lifecycle {
    precondition {
      condition     = length(local.parsed) > 0
      error_message = "No OpenAPI specs found in ${local.spec_folder_path}"
    }
  }
}

resource "azurerm_api_management_api_version_set" "vs" {
  for_each            = local.families
  name                = "vs-${each.key}"
  resource_group_name = var.resource_group_name
  api_management_name = var.api_management_name
  display_name        = each.value.display_name
  versioning_scheme   = "Segment"
}

resource "azurerm_api_management_api" "apis" {
  for_each = merge([
    for path, fam in local.families : {
      for vkey, v in fam.versions : vkey => {
        api_path = path
        dn       = fam.display_name
        vstr     = v.version_str
        file     = v.original_file
        desc     = v.description
        url      = v.dynamic_backend_url
        tags     = v.tags
      }
    }
  ]...)

  resource_group_name = var.resource_group_name
  api_management_name = var.api_management_name

  name         = each.key
  display_name = each.value.dn
  description  = length(each.value.desc) > 0 ? each.value.desc : null
  path         = each.value.api_path
  protocols    = ["https"]
  service_url  = each.value.url

  version_set_id        = azurerm_api_management_api_version_set.vs[each.value.api_path].id
  version               = each.value.vstr
  revision              = "1"
  subscription_required = var.subscription_required

  subscription_key_parameter_names {
    header = var.subscription_key_header_name
    query  = var.subscription_key_query_param_name
  }

  import {
    content_format = "openapi"
    # Let Terraform own APIM API tags via info.x-tags by stripping x-tags from import payload.
    content_value = join("\n", [
      for line in split("\n", file("${local.spec_folder_path}/${each.value.file}")) : line
      if !startswith(trimspace(line), "x-tags:")
    ])
  }
}

# API Tags: create and assign
locals {
  tag_pairs = flatten([
    for path, fam in local.families : [
      for vkey, v in fam.versions : [for t in v.tags : { api_key = vkey, tag = t }]
    ]
  ])
  tag_names = toset([for p in local.tag_pairs : p.tag])
}

resource "azurerm_api_management_tag" "tag" {
  for_each          = local.tag_names
  api_management_id = data.azurerm_api_management.apim.id
  name              = each.key
  display_name      = each.key
}

resource "azurerm_api_management_api_tag" "assign" {
  for_each = { for p in local.tag_pairs : "${p.api_key}|${p.tag}" => p }

  name   = each.value.tag
  api_id = azurerm_api_management_api.apis[each.value.api_key].id
}

# Optional API policy referencing platform fragments
resource "azurerm_api_management_api_policy" "api_policy" {
  for_each            = var.attach_api_policy ? azurerm_api_management_api.apis : {}
  resource_group_name = var.resource_group_name
  api_management_name = var.api_management_name
  api_name            = each.value.name
  xml_content         = file("${path.module}/api_policy.xml")
}
