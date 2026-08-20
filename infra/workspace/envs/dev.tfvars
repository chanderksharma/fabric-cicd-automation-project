# Per-environment differences only.
#
# Nothing that can be derived is repeated here. The workspace name, the capacity
# name and the Git branch all come from prefix + lane + environment, so this file
# stays identical across both lanes and there is no value to keep in sync.

environment = "dev"

# The dev capacity is suspended outside working hours, so infrastructure applies
# must not fail on an inactive capacity.
skip_capacity_state_validation = true
