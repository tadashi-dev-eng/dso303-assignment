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
  description = "AWS Region for the platform (Assignment 3: Asia Pacific (Singapore)). CloudFront-scoped WAF and ACM always go to us-east-1 through the aws.us_east_1 provider."
  type        = string
  default     = "ap-southeast-1"
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
  default     = ["ap-southeast-1a", "ap-southeast-1b"]

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

variable "aurora_min_acu" {
  description = "Aurora Serverless v2 minimum capacity (ACU). 0.5 outside exams; exam-window.sh raises it to 4 before an exam starts."
  type        = number
  default     = 0.5
}

variable "aurora_max_acu" {
  description = "Aurora Serverless v2 maximum capacity (ACU). Caps the bill and is far above the measured exam peak."
  type        = number
  default     = 16
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention. 30 days covers an exam dispute window; records themselves live in Aurora/DynamoDB/S3."
  type        = number
  default     = 30
}

variable "xray_sampling_rate" {
  description = "Fraction of requests traced by X-Ray after the 1 request/s reservoir."
  type        = number
  default     = 0.01
}

variable "waf_per_user_limit" {
  description = "Requests per 5 minutes allowed per signed-in user (Authorization header). Autosave alone is 10 per 5 min."
  type        = number
  default     = 600
}

variable "waf_per_ip_limit" {
  description = "Requests per 5 minutes per source IP. A whole exam hall shares one campus NAT IP: 3,000 students x 10 autosaves = 30,000."
  type        = number
  default     = 100000
}

variable "lambda_reserved_concurrency" {
  description = "Concurrency reserved for the exam API so marking jobs can never starve it. Exam peak needs ~15 (Little's law), so 200 is >10x headroom."
  type        = number
  default     = 200
}

variable "lambda_provisioned_concurrency" {
  description = "Warm API instances kept during scheduled exam windows (0 = off). exam-window.sh sets 50 for the first hour of an exam."
  type        = number
  default     = 0
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

variable "retention_years" {
  description = "Records retention requirement."
  type        = number
  default     = 5
}

variable "exam_cache_seconds" {
  description = "How long each warm api Lambda keeps an exam and its questions (load-test fix B1). 0 = every request reads Aurora."
  type        = number
  default     = 60
}
