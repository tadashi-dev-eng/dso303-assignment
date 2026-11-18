# Real AWS production deployment.
environment                    = "prod"
use_floci                      = false
region                         = "us-east-1"
azs                            = ["us-east-1a", "us-east-1b"]
domain_name                    = "exams.example-university.edu"
enable_edge                    = true
enable_rds                     = true
enable_nat_gateways            = true
lambda_in_vpc                  = true
db_instance_class              = "db.r6g.large"
lambda_reserved_concurrency    = 600
lambda_provisioned_concurrency = 0 # raised to 300 by the exam-week schedule (scripts/exam-window.sh)
