variable "project" {
  description = "Name prefix for every resource."
  type        = string
  default     = "exams"
}

variable "environment" {
  description = "Deployment environment (floci, prod)."
  type        = string
  default     = "prod"
}

variable "region" {
  description = "AWS Region. us-east-1 so CloudFront-scoped WAF and ACM live in the same Region."
  type        = string
  default     = "us-east-1"
}

variable "use_floci" {
  description = "Point the provider at the Floci local AWS emulator instead of real AWS."
  type        = bool
  default     = false
}

variable "floci_endpoint" {
  description = "Floci endpoint URL."
  type        = string
  default     = "http://localhost:4566"
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "azs" {
  description = "Exactly two Availability Zones."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]

  validation {
    condition     = length(var.azs) == 2
    error_message = "The design is built for exactly two Availability Zones."
  }
}

variable "domain_name" {
  description = "Public hosted zone for the platform."
  type        = string
  default     = "exams.example-university.edu"
}

variable "notification_sender" {
  description = "Verified SES identity that sends result and submission emails."
  type        = string
  default     = "no-reply@exams.example-university.edu"
}

variable "alarm_email" {
  description = "Operations email subscribed to the CloudWatch alarm topic."
  type        = string
  default     = "ops@exams.example-university.edu"
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.medium"
}

variable "lambda_reserved_concurrency" {
  description = "Concurrency reserved for the exam API so marking jobs can never starve it."
  type        = number
  default     = 600
}

variable "lambda_provisioned_concurrency" {
  description = "Warm API instances kept during scheduled exam windows (0 = off, e.g. in Floci)."
  type        = number
  default     = 0
}

variable "enable_nat_gateways" {
  description = "One NAT gateway per AZ. Disable in Floci to keep the emulator light."
  type        = bool
  default     = true
}

variable "enable_edge" {
  description = "Create CloudFront, WAF and Route 53 (edge layer)."
  type        = bool
  default     = true
}

variable "enable_cdn" {
  description = "Create the CloudFront distribution. Off in Floci: its CloudFront API omits TrustedSigners and crashes the AWS provider."
  type        = bool
  default     = true
}

variable "enable_rds" {
  description = "Create the Aurora PostgreSQL cluster (writer AZ-a, reader AZ-b)."
  type        = bool
  default     = true
}

variable "lambda_in_vpc" {
  description = "Attach Lambda functions to the private app subnets (true in AWS)."
  type        = bool
  default     = true
}

variable "retention_years" {
  description = "Records retention requirement."
  type        = number
  default     = 5
}
