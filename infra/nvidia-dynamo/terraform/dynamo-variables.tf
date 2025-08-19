# NVIDIA Dynamo specific variables
# These are merged with base variables during deployment

# Flag to enable Dynamo stack
variable "enable_dynamo_stack" {
  description = "Enable NVIDIA Dynamo addon"
  type        = bool
  default     = false
}

# Dynamo version
variable "dynamo_stack_version" {
  description = "NVIDIA Dynamo default version"
  type        = string
  default     = "0.4.0"
}