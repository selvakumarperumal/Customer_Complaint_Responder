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

variable "enable_irsa" {
  description = "Create an IRSA role so the backend pod can read the secret"
  type        = bool
  default     = true
}

variable "oidc_provider_arn" {
  description = "ARN of the EKS OIDC provider (required when enable_irsa = true)"
  type        = string
  default     = ""
}

variable "oidc_provider_url" {
  description = "URL of the EKS OIDC provider, with https:// prefix (required when enable_irsa = true)"
  type        = string
  default     = ""
}

variable "namespace" {
  description = "Kubernetes namespace where the backend service account lives"
  type        = string
  default     = "default"
}

variable "service_account_name" {
  description = "Name of the Kubernetes service account for the backend"
  type        = string
  default     = "backend"
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
