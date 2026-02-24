provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      region        = var.aws_region
      app-id        = var.app_id
      environment   = var.environment
      engineer_mail = var.mail
    }
  }
}

variable "aws_region" {
  description = "provide the aws_region"
  type        = string
  default     = "us-east-1"
}

variable "app_id" {
  description = "provide an app-id"
  type        = string
  default     = "0312"
}

variable "environment" {
  description = "provide some environment name"
  type        = string
  default     = "develop"
}

variable "mail" {
  description = "provide an email to send mails"
  type        = string
  default     = "vamsikrishnab1992@gmail.com"
}

variable "create_acl" {
  description = "Whether to create ACLs and users for MemoryDB"
  type        = bool
  default     = true
}

variable "create_multi_region_cluster" {
  description = "Whether to create a multi-region cluster"
  type        = bool
}

data "aws_caller_identity" "current" {}

data "aws_kms_key" "kms_key" {
  key_id = "alias/kms-${var.environment}-${var.aws_region}"
}

data "aws_vpcs" "default" {
  filter {
    name   = "tag:Name"
    values = ["vpc-${var.environment}-${var.aws_region}"]
  }
}

data "aws_vpc" "selected" {
  id = tolist(data.aws_vpcs.default.ids)[0]
}


data "aws_subnets" "default_private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.selected.id]
  }
  filter {
    name   = "tag:Tier"
    values = ["Private"]
  }
}

data "aws_secretsmanager_secret" "secrets" {
  name = "secret-${var.aws_region}-${var.environment}"
}

data "aws_secretsmanager_secret_version" "secrets_version" {
  secret_id = data.aws_secretsmanager_secret.secrets.id
}

locals {
  account_id = data.aws_caller_identity.current.account_id

  secret_json = jsondecode(data.aws_secretsmanager_secret_version.secrets_version.secret_string)

  redis_password = local.secret_json.password

  access_levels = {
    read = {
      access_string = join(" ", [
        "on ~* &* -@all",
        "+@read",
        "+@connection",
        "+@pubsub",
        "+cluster|slots +cluster|nodes +cluster|info +cluster|myid",
        "+info +wait",
        "+exists +type +ttl +pttl",
      ])
    }

    readwrite = {
      access_string = join(" ", [
        "on ~* &* -@all",
        "+@read +@write +@keyspace",
        "+@connection",
        "+@transaction",
        "+@pubsub",
        "+cluster|slots +cluster|nodes +cluster|info +cluster|myid",
        "+info +wait",
      ])
    }

    admin = {
      access_string = "on ~* &* +@all"
    }
  }
}

resource "aws_security_group" "this" {
  name_prefix = "memorydb-${var.environment}-${var.aws_region}-security-group"
  description = "Security group for MemoryDB cluster"
  vpc_id      = data.aws_vpc.selected.id

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group_rule" "ingress_cidr" {
  type              = "ingress"
  from_port         = 6379
  to_port           = 6379
  protocol          = "tcp"
  cidr_blocks       = [data.aws_vpc.selected.cidr_block]
  security_group_id = aws_security_group.this.id
  description       = "Allow inbound traffic from VPC CIDR"
}

resource "aws_security_group_rule" "egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.this.id
  description       = "Allow all outbound traffic"
}

resource "aws_memorydb_subnet_group" "this" {
  name       = "memorydb-${var.environment}-${var.aws_region}-subnet-group"
  subnet_ids = data.aws_subnets.default_private.ids
}

resource "aws_memorydb_parameter_group" "this" {
  name   = "memorydb-${var.environment}-${var.aws_region}-parameter-group"
  family = "memorydb_valkey7"

  parameter {
    name  = "maxmemory-policy"
    value = "allkeys-lru"
  }
}

resource "aws_memorydb_acl" "this" {
  name = "memorydb-${var.environment}-${var.aws_region}-acl"
  user_names = sort([
    for user in aws_memorydb_user.this : user.user_name
  ])

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    aws_memorydb_user.this
  ]
}

resource "aws_memorydb_user" "this" {
  for_each      = var.create_acl ? local.access_levels : {}
  user_name     = "memorydb-${var.environment}-user-${each.key}"
  access_string = each.value.access_string

  authentication_mode {
    type      = "password"
    passwords = [local.redis_password]
  }
}

resource "aws_memorydb_multi_region_cluster" "example" {
  count = var.create_multi_region_cluster ? 1 : 0

  multi_region_cluster_name_suffix = "memorydb-${var.environment}-multi-region-cluster"
  node_type                        = "db.r7g.xlarge"
  description                      = "Global MemoryDB multi-region cluster"
  engine                           = "valkey"
  engine_version                   = "7.3"
  num_shards                       = 2
  tls_enabled                      = true
}

resource "aws_memorydb_cluster" "this" {
  name                       = "memorydb-${var.environment}-${var.aws_region}-cluster"
  node_type                  = var.create_multi_region_cluster ? "db.r7g.xlarge" : "db.t4g.small"
  num_shards                 = var.create_multi_region_cluster ? 2 : 1
  num_replicas_per_shard     = var.create_multi_region_cluster ? 1 : 0
  acl_name                   = aws_memorydb_acl.this.name
  subnet_group_name          = aws_memorydb_subnet_group.this.name
  parameter_group_name       = var.create_multi_region_cluster ? null : aws_memorydb_parameter_group.this.name
  multi_region_cluster_name  = var.create_multi_region_cluster ? aws_memorydb_multi_region_cluster.example[0].multi_region_cluster_name : null
  port                       = 6379
  tls_enabled                = true
  kms_key_arn                = data.aws_kms_key.kms_key.arn
  snapshot_retention_limit   = 0
  snapshot_window            = "03:00-05:00"
  maintenance_window         = "sun:05:00-sun:07:00"
  security_group_ids         = [aws_security_group.this.id]
  auto_minor_version_upgrade = true
  data_tiering               = false
  description                = "Global MemoryDB cluster for multi-region active-active replication"
  engine                     = "valkey"
  engine_version             = 7.3
  sns_topic_arn              = null
  depends_on                 = [aws_memorydb_multi_region_cluster.example]
}

variable "aws_region" {
  description = "provide the aws_region"
  type        = string
  default     = "us-east-1"
}

variable "app_id" {
  description = "provide an app-id"
  type        = string
  default     = "0312"
}

variable "environment" {
  description = "provide some environment name"
  type        = string
  default     = "develop"
}

variable "mail" {
  description = "provide an email to send mails"
  type        = string
  default     = "vamsikrishnab1992@gmail.com"
}

variable "create_acl" {
  description = "Whether to create ACLs and users for MemoryDB"
  type        = bool
  default     = true
}

variable "create_multi_region_cluster" {
  description = "Whether to create a multi-region cluster"
  type        = bool
}

output "region" {
  value = var.aws_region
}

output "account_id" {
  value = local.account_id
}

output "environment" {
  value = var.environment
}

output "memorydb_cluster_name" {
  value = aws_memorydb_cluster.this.name
}

output "memorydb_security_group_id" {
  value = aws_security_group.this.id
}

output "memorydb_subnet_group_name" {
  value = aws_memorydb_subnet_group.this.name
}

output "memorydb_acl_name" {
  value = aws_memorydb_acl.this.name
}

output "memorydb_user_names" {
  value = [for u in aws_memorydb_user.this : u.user_name]
}

output "memorydb_multi_region_cluster_name" {
  value = try(aws_memorydb_multi_region_cluster.example[0].multi_region_cluster_name, null)
}
