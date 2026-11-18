# Local deployment against the Floci AWS emulator (http://localhost:4566), Singapore Region.
# environment "sg" keeps every name (exams-sg-*) apart from the Assignment 2 stack (exams-floci-*).
environment                    = "sg"
use_floci                      = true
region                         = "ap-southeast-1"
azs                            = ["ap-southeast-1a", "ap-southeast-1b"]
enable_edge                    = true
enable_rds                     = true
lambda_reserved_concurrency    = 200
lambda_provisioned_concurrency = 0
enable_cdn                     = false # Floci CloudFront API crashes the AWS provider (see README)
