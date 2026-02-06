locals {
  name = var.name_prefix
  tags = {
    Project = "wiz-tech-exercise"
    Owner   = var.your_name
    Lab     = "true"
  }
}

# ---------------------------
# Networking (VPC)
# ---------------------------
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.6.0"

  name = "${local.name}-vpc"
  cidr = "10.0.0.0/16"

  azs             = slice(data.aws_availability_zones.available.names, 0, 2)
  public_subnets  = ["10.0.0.0/24", "10.0.1.0/24"]
  private_subnets = ["10.0.10.0/24", "10.0.11.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }

  tags = local.tags
}

# ---------------------------
# EKS Cluster (nodes in private subnets)
# ---------------------------
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.24.0"

  cluster_name    = "${local.name}-eks"
  cluster_version = "1.29"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # For interview/demo convenience from your laptop:
  # - endpoint is public
  # - worker nodes are private subnets (meets "cluster in private subnet" intent)
  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true

  cluster_enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  eks_managed_node_groups = {
    default = {
      instance_types = ["t3.medium"]
      min_size       = 2
      max_size       = 3
      desired_size   = 2
    }
  }

  tags = local.tags
}

data "aws_eks_cluster" "this" {
  count = var.deploy_k8s ? 1 : 0
  name  = module.eks.cluster_name

  # Makes intent explicit; avoids edge timing issues.
  depends_on = [module.eks]
}

data "aws_eks_cluster_auth" "this" {
  count = var.deploy_k8s ? 1 : 0
  name  = module.eks.cluster_name

  depends_on = [module.eks]
}


# ---------------------------
# Container Registry (ECR)
# ---------------------------
resource "aws_ecr_repository" "wizapp" {
  name = "${local.name}-wizapp"
  image_scanning_configuration {
    scan_on_push = true
  }
  tags = local.tags
}

# ---------------------------
# S3 bucket for MongoDB backups (INTENTIONALLY PUBLIC READ + LIST)
# ---------------------------
resource "random_id" "suffix" {
  byte_length = 3
}

resource "aws_s3_bucket" "backups" {
  bucket        = "${local.name}-mongo-backups-${random_id.suffix.hex}"
  force_destroy = true
  tags          = local.tags
}

# Intentionally disable public access block so public bucket policy works
resource "aws_s3_bucket_public_access_block" "backups" {
  bucket                  = aws_s3_bucket.backups.id
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

# Intentionally allow public listing + read
resource "aws_s3_bucket_policy" "backups_public" {
  bucket = aws_s3_bucket.backups.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PublicList"
        Effect    = "Allow"
        Principal = "*"
        Action    = ["s3:ListBucket"]
        Resource  = [aws_s3_bucket.backups.arn]
      },
      {
        Sid       = "PublicRead"
        Effect    = "Allow"
        Principal = "*"
        Action    = ["s3:GetObject"]
        Resource  = ["${aws_s3_bucket.backups.arn}/*"]
      }
    ]
  })
  depends_on = [aws_s3_bucket_public_access_block.backups]
}

# ---------------------------
# MongoDB VM: outdated Linux, SSH public, Mongo only from EKS nodes, auth enabled
# ---------------------------
# Outdated Linux: Ubuntu 20.04 (1+ year outdated)
data "aws_ami" "ubuntu_2004" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_key_pair" "mongo" {
  key_name   = "${local.name}-mongo"
  public_key = file(var.public_key_path)
  tags       = local.tags
}

# Security group: SSH public (intentional), Mongo restricted to EKS node SG
resource "aws_security_group" "mongo_vm" {
  name        = "${local.name}-mongo-vm-sg"
  description = "Mongo VM SG (intentional public SSH)."
  vpc_id      = module.vpc.vpc_id
  tags        = local.tags
}

resource "aws_vpc_security_group_ingress_rule" "mongo_ssh_public" {
  security_group_id = aws_security_group.mongo_vm.id
  cidr_ipv4         = var.ssh_allowed_cidr
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  description       = "INTENTIONAL: SSH exposed to public internet"
}

# Restrict MongoDB port to EKS node security group only
resource "aws_vpc_security_group_ingress_rule" "mongo_from_eks_nodes" {
  security_group_id            = aws_security_group.mongo_vm.id
  referenced_security_group_id = module.eks.node_security_group_id
  from_port                    = 27017
  to_port                      = 27017
  ip_protocol                  = "tcp"
  description                  = "MongoDB only reachable from Kubernetes node SG"
}

resource "aws_vpc_security_group_egress_rule" "mongo_all" {
  security_group_id = aws_security_group.mongo_vm.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Allow all egress"
}

# IAM role for Mongo VM - includes S3 write for backups and INTENTIONALLY permissive EC2 permissions
data "aws_iam_policy_document" "mongo_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "mongo_vm" {
  name               = "${local.name}-mongo-vm-role"
  assume_role_policy = data.aws_iam_policy_document.mongo_assume.json
  tags               = local.tags
}

resource "aws_iam_instance_profile" "mongo_vm" {
  name = "${local.name}-mongo-vm-profile"
  role = aws_iam_role.mongo_vm.name
}

# S3 write permission for backups
data "aws_iam_policy_document" "mongo_s3" {
  statement {
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:PutObjectAcl",
      "s3:AbortMultipartUpload",
      "s3:ListBucket",
      "s3:GetBucketLocation"
    ]
    resources = [
      aws_s3_bucket.backups.arn,
      "${aws_s3_bucket.backups.arn}/*"
    ]
  }
}

resource "aws_iam_policy" "mongo_s3" {
  name   = "${local.name}-mongo-s3"
  policy = data.aws_iam_policy_document.mongo_s3.json
}

resource "aws_iam_role_policy_attachment" "mongo_s3" {
  role       = aws_iam_role.mongo_vm.name
  policy_arn = aws_iam_policy.mongo_s3.arn
}

# INTENTIONAL: overly permissive EC2 permissions (example: able to create VMs)
data "aws_iam_policy_document" "mongo_permissive" {
  statement {
    effect = "Allow"
    actions = [
      "ec2:*",
      "iam:PassRole"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "mongo_permissive" {
  count  = var.enable_overly_permissive_ec2_role ? 1 : 0
  name   = "${local.name}-mongo-permissive"
  policy = data.aws_iam_policy_document.mongo_permissive.json
}

resource "aws_iam_role_policy_attachment" "mongo_permissive" {
  count      = var.enable_overly_permissive_ec2_role ? 1 : 0
  role       = aws_iam_role.mongo_vm.name
  policy_arn = aws_iam_policy.mongo_permissive[0].arn
}

# User-data installs outdated MongoDB (5.0) and configures auth + daily backups to S3
locals {
  mongo_user_data = templatefile("${path.module}/userdata/mongo_user_data.sh.tftpl", {
    backups_bucket       = aws_s3_bucket.backups.bucket
    aws_region           = var.aws_region
    mongo_admin_user     = var.mongo_admin_user
    mongo_admin_password = var.mongo_admin_password
    mongo_app_user       = var.mongo_app_user
    mongo_app_password   = var.mongo_app_password
    mongo_db_name        = var.mongo_db_name
  })
}

resource "aws_instance" "mongo" {
  ami                         = data.aws_ami.ubuntu_2004.id
  instance_type               = "t3.small"
  subnet_id                   = module.vpc.public_subnets[0]
  vpc_security_group_ids      = [aws_security_group.mongo_vm.id]
  key_name                    = aws_key_pair.mongo.key_name
  iam_instance_profile        = aws_iam_instance_profile.mongo_vm.name
  associate_public_ip_address = true # so SSH is reachable publicly (intentional)

  user_data = local.mongo_user_data

  tags = merge(local.tags, { Name = "${local.name}-mongo-vm" })
}

# ---------------------------
# Cloud-native security tooling (audit + detective)
# ---------------------------
# CloudTrail (management events)
resource "aws_cloudwatch_log_group" "cloudtrail" {
  name              = "/wiz/${local.name}/cloudtrail"
  retention_in_days = 7
  tags              = local.tags
}

data "aws_iam_policy_document" "cloudtrail_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cloudtrail" {
  name               = "${local.name}-cloudtrail-role"
  assume_role_policy = data.aws_iam_policy_document.cloudtrail_assume.json
  tags               = local.tags
}

data "aws_iam_policy_document" "cloudtrail_logs" {
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = ["${aws_cloudwatch_log_group.cloudtrail.arn}:*"]
  }
}

resource "aws_iam_role_policy" "cloudtrail_logs" {
  name   = "${local.name}-cloudtrail-logs"
  role   = aws_iam_role.cloudtrail.id
  policy = data.aws_iam_policy_document.cloudtrail_logs.json
}

resource "aws_s3_bucket" "cloudtrail" {
  bucket        = "${local.name}-cloudtrail-${random_id.suffix.hex}"
  force_destroy = true
  tags          = local.tags
}

data "aws_iam_policy_document" "cloudtrail_bucket_policy" {
  statement {
    sid     = "AWSCloudTrailAclCheck"
    effect  = "Allow"
    actions = ["s3:GetBucketAcl"]

    resources = [aws_s3_bucket.cloudtrail.arn]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
  }

  statement {
    sid     = "AWSCloudTrailWrite"
    effect  = "Allow"
    actions = ["s3:PutObject"]

    resources = [
      "${aws_s3_bucket.cloudtrail.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
    ]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }
}

resource "aws_s3_bucket_policy" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  policy = data.aws_iam_policy_document.cloudtrail_bucket_policy.json
}


resource "aws_cloudtrail" "this" {
  name                          = "${local.name}-trail"
  s3_bucket_name                = aws_s3_bucket.cloudtrail.id
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_logging                = true
  cloud_watch_logs_group_arn    = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
  cloud_watch_logs_role_arn     = aws_iam_role.cloudtrail.arn
  tags                          = local.tags

  depends_on = [aws_s3_bucket_policy.cloudtrail]
}

# Detective control: EventBridge rule for sensitive changes -> CloudWatch Logs
resource "aws_cloudwatch_log_group" "detections" {
  name              = "/wiz/${local.name}/detections"
  retention_in_days = 7
  tags              = local.tags
}

resource "aws_cloudwatch_event_rule" "sensitive_api" {
  name = "${local.name}-sensitive-api"
  event_pattern = jsonencode({
    "source" : ["aws.ec2", "aws.s3"],
    "detail-type" : ["AWS API Call via CloudTrail"],
    "detail" : {
      "eventName" : [
        "AuthorizeSecurityGroupIngress",
        "PutBucketPolicy",
        "PutBucketAcl",
        "CreateSecurityGroup"
      ]
    }
  })
  tags = local.tags
}

resource "aws_cloudwatch_event_target" "sensitive_api_to_logs" {
  rule      = aws_cloudwatch_event_rule.sensitive_api.name
  target_id = "toCloudWatchLogs"
  arn       = aws_cloudwatch_log_group.detections.arn
}

# Allow EventBridge to write to log group
resource "aws_cloudwatch_log_resource_policy" "events_to_logs" {
  policy_name = "${local.name}-events-to-logs"
  policy_document = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Principal = { Service = "events.amazonaws.com" },
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      Resource = "${aws_cloudwatch_log_group.detections.arn}:*"
    }]
  })
}
