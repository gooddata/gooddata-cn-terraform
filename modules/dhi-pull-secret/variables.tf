variable "access_token" {
  description = "Docker Hub PAT used to pull Docker Hardened Images from dhi.io."
  type        = string
  sensitive   = true
}

variable "username" {
  description = "Docker Hub username used to pull Docker Hardened Images from dhi.io."
  type        = string
}

variable "namespaces" {
  description = "Namespaces that get the pull secret, as a map of a static key to the namespace name."
  type        = map(string)
}

variable "consumers" {
  description = "Verb phrase for the error message, for example \"platform components are\"."
  type        = string
}

variable "registry" {
  description = "Registry host of the Docker Hardened Images."
  type        = string
  default     = "dhi.io"
}

variable "secret_name" {
  description = "Name of the pull secret in every namespace."
  type        = string
  default     = "dhi-pull-secret"
}
