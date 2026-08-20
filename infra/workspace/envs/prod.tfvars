# Per-environment differences only. Names derive from prefix + lane + environment.

environment = "prod"

# Currently the shared F2. To give prod dedicated compute:
#   1. add `prod = { sku = "F8" }` to var.capacities in the platform root
#   2. apply the platform root
#   3. set capacity_key = "prod" here

# No human write access in prod. role_overrides is deliberately left empty;
# a break-glass grant must arrive as a reviewed pull request.
role_overrides = {}
