# Real AWS production deployment - Asia Pacific (Singapore).
environment                    = "prod"
use_floci                      = false
region                         = "ap-southeast-1"
azs                            = ["ap-southeast-1a", "ap-southeast-1b"]
domain_name                    = "exams.example-university.edu"
enable_edge                    = true
enable_rds                     = true
aurora_min_acu                 = 0.5 # exam-window.sh raises it to 4 before an exam
aurora_max_acu                 = 16
lambda_reserved_concurrency    = 200
lambda_provisioned_concurrency = 0 # exam-window.sh sets 50 for the first hour of each exam
log_retention_days             = 30
xray_sampling_rate             = 0.01
