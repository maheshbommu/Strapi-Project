variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  type    = string
  default = "strapi-app"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.11.0/24", "10.0.12.0/24"]
}

variable "db_username" {
  type    = string
  default = "strapiadmin"
}

variable "db_password" {
  type        = string
  description = "DB password (override via tfvars or CI)"
  default     = null
}

variable "allowed_cidr" {
  description = "CIDR allowed to reach ALB (0.0.0.0/0 for public)"
  type        = string
  default     = "0.0.0.0/0"
}
