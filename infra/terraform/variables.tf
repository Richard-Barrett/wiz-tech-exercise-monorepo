variable "aws_region" {
  type        = string
  description = "AWS region"
}

variable "deploy_k8s" {
  type    = bool
  default = false
}

variable "eks_admin_principal_arn" {
  type        = string
  description = "IAM principal ARN to grant EKS admin access via EKS Access Entry."
}

variable "name_prefix" {
  type        = string
  description = "Name prefix for resources"
  default     = "wizex"
}

variable "your_name" {
  type        = string
  description = "Your name written into wizexercise.txt in the container image"
  default     = "Richard Barrett"
}

variable "public_key_path" {
  type        = string
  description = "Path to SSH public key for MongoDB VM access"
}

variable "ssh_allowed_cidr" {
  type        = string
  description = "CIDR allowed to SSH to Mongo VM. Exercise requires public SSH; default is 0.0.0.0/0."
  default     = "0.0.0.0/0"
}

variable "mongo_admin_user" {
  type    = string
  default = "admin"
}

variable "mongo_admin_password" {
  type        = string
  sensitive   = true
  description = "Lab password (intentionally simple). Change if desired."
}

variable "mongo_app_user" {
  type    = string
  default = "wizapp"
}

variable "mongo_app_password" {
  type        = string
  sensitive   = true
  description = "Lab password (intentionally simple). Change if desired."
}

variable "mongo_db_name" {
  type    = string
  default = "wizdb"
}

# Intentionally permissive instance policy toggle (kept ON by default for exercise)
variable "enable_overly_permissive_ec2_role" {
  type    = bool
  default = true
}
