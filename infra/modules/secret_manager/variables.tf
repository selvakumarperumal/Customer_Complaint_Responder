variable "cluster_name" {
  description = "Name of the EKS cluster (used for resource naming)"
  type        = string
}

variable "secret_name" {
  description = "Name / path of the secret in AWS Secrets Manager"
  type        = string
  default     = "ccr/google-api-key"
}

variable "secret_value" {
  description = "The Google / Gemini API key value to store"
  type        = string
  sensitive   = true
}

variable "enable_pod_identity" {
  description = "Create the IAM role used by Pod Identity associations for the backend and ESO"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
