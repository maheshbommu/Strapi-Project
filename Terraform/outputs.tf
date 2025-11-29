output "alb_url" {
  description = "ALB URL"
  value       = aws_lb.alb.dns_name
}
output "ecr_repository_url" {
  value = aws_ecr_repository.repo.repository_url
}
output "s3_bucket" {
  value = aws_s3_bucket.uploads.bucket
}
output "db_secret_arn" {
  value = aws_secretsmanager_secret.db_secret.arn
}
