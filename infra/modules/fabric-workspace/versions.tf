terraform {
  required_version = ">= 1.9.0"

  required_providers {
    fabric = {
      source  = "microsoft/fabric"
      version = ">= 1.2.0, < 2.0.0"
    }
  }
}
