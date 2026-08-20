resource "azurerm_role_assignment" "this" {
  for_each = var.assignments

  scope                = each.value.scope
  role_definition_name = each.value.role_definition_name
  principal_id         = each.value.principal_id
  description          = each.value.description

  # Required so the provider does not need Graph read permission to infer the
  # principal type, and so it does not fail on newly created principals that
  # have not yet replicated.
  principal_type                   = each.value.principal_type
  skip_service_principal_aad_check = each.value.principal_type == "ServicePrincipal"
}
