output "aws_region" {
  value = var.aws_region
}

output "eks_cluster_name" {
  value = module.eks.cluster_name
}

output "ecr_repo_url" {
  value = aws_ecr_repository.wizapp.repository_url
}

output "backups_bucket_name" {
  value = aws_s3_bucket.backups.bucket
}

output "mongo_private_ip" {
  value = aws_instance.mongo.private_ip
}

output "mongo_public_ip" {
  value = aws_instance.mongo.public_ip
}

output "mongo_connection_string" {
  value     = "mongodb://${var.mongo_app_user}:${var.mongo_app_password}@${aws_instance.mongo.private_ip}:27017/${var.mongo_db_name}?authSource=${var.mongo_db_name}"
  sensitive = true
}

output "your_name" {
  value = var.your_name
}
