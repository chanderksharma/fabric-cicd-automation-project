locals {
  # Azure rejects hyphens and uppercase in Fabric capacity names.
  capacity_name = lower(replace(var.name, "-", ""))
}

resource "azurerm_fabric_capacity" "this" {
  name                = local.capacity_name
  resource_group_name = var.resource_group_name
  location            = var.location

  administration_members = var.administration_members

  sku {
    name = var.sku
    tier = "Fabric"
  }

  tags = var.tags

  lifecycle {
    # A suspended capacity still reports its configured SKU, so pausing the
    # capacity out-of-band (az fabric capacity suspend/resume) never produces a
    # diff here. Admin membership is intentionally NOT ignored - it is the
    # control that lets the CI/CD principal read the capacity.
    precondition {
      condition     = length(local.capacity_name) >= 3 && length(local.capacity_name) <= 63
      error_message = "Normalised capacity name must be 3-63 characters after hyphen removal."
    }
  }
}
