# Local deployment against the Floci AWS emulator (http://localhost:4566).
environment                    = "floci"
use_floci                      = true
region                         = "us-east-1"
enable_edge                    = true
enable_rds                     = true
enable_nat_gateways            = true
lambda_in_vpc                  = true
lambda_reserved_concurrency    = 100
lambda_provisioned_concurrency = 0
enable_cdn                     = false # Floci CloudFront API crashes the AWS provider (see README)
