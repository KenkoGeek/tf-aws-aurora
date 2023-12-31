# terraform {
#   backend "s3" {
#     bucket = "my-terraform-state-bucket"
#     key    = "my-terraform-state-key"
#     region = var.aws_region
#     # dynamodb_table = "my-terraform-state-lock"
#   }
# }

resource "random_id" "id" {
  byte_length = 8
}

# RDS Aurora pre-req
resource "aws_db_subnet_group" "aurora_subnet_group" {
  name       = "${var.project_name}-${var.db_engine}-subnet-group"
  subnet_ids = var.subnets
}

resource "aws_security_group" "aurora_sg" {
  name        = "${var.project_name}-${var.db_engine}-sg"
  description = "Security group for RDS Aurora"
  vpc_id      = var.vpc_id
  tags = merge(var.tags, {
    Name = "${var.project_name}-${var.db_engine}-sg"
  })

  ingress {
    description = "Allow incoming database connections"
    from_port   = var.db_engine == "aurora-mysql" ? 3306 : 5432
    to_port     = var.db_engine == "aurora-mysql" ? 3306 : 5432
    protocol    = "tcp"
    cidr_blocks = split(",", var.allowed_ip_addresses)
  }

  egress {
    description = "Allow outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"] #tfsec:ignore:aws-vpc-no-public-egress-sgr
  }
}

resource "aws_security_group_rule" "local_vpc" {
  type              = "ingress"
  description       = "Allow incoming database connections"
  from_port         = var.db_engine == "aurora-mysql" ? 3306 : 5432
  to_port           = var.db_engine == "aurora-mysql" ? 3306 : 5432
  protocol          = "tcp"
  cidr_blocks       = [data.aws_vpc.main.cidr_block]
  security_group_id = aws_security_group.aurora_sg.id
}

resource "aws_rds_cluster_parameter_group" "aurora" {
  name        = "${var.project_name}-parameter-group"
  family      = var.db_engine == "mysql" ? "aurora-mysql5.7" : "aurora-postgresql10"
  description = "Parameter group for Aurora cluster"
  tags        = var.tags
}

#tfsec:ignore:aws-ssm-secret-use-customer-key
resource "aws_secretsmanager_secret" "aurora_password_secret" {
  name                    = "${var.project_name}-password-secret-${lower(random_id.id.hex)}"
  recovery_window_in_days = 7
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "aurora_password_version" {
  secret_id     = aws_secretsmanager_secret.aurora_password_secret.id
  secret_string = random_password.aurora_password.result
}

# RDS Aurora cluster
resource "aws_rds_cluster" "aurora" {
  cluster_identifier          = "${var.project_name}-aurora"
  apply_immediately           = true
  engine                      = var.db_engine
  engine_version              = var.db_engine == "aurora-mysql" ? "5.7.mysql_aurora.2.11.3" : "15.2"
  database_name               = var.db_name
  final_snapshot_identifier   = "${var.project_name}-${lower(random_id.id.hex)}-snapshot"
  master_username             = var.db_username
  master_password             = aws_secretsmanager_secret_version.aurora_password_version.secret_string
  port                        = var.db_engine == "aurora-mysql" ? 3306 : 5432
  backup_retention_period     = var.backup_retention_period
  availability_zones          = slice(data.aws_availability_zones.available.names, 0, 2)
  db_subnet_group_name        = aws_db_subnet_group.aurora_subnet_group.name
  vpc_security_group_ids      = [aws_security_group.aurora_sg.id]
  copy_tags_to_snapshot       = true
  allow_major_version_upgrade = var.enable_major_version_upgrade
  storage_encrypted           = true
  kms_key_id                  = var.kms_key_arn == "" ? data.aws_kms_key.default_rds.arn : var.kms_key_arn
  backtrack_window            = var.db_engine == "aurora-mysql" ? var.backtrack_window : 0
  enabled_cloudwatch_logs_exports = [
    var.db_engine == "aurora-mysql" ? "audit" : "postgresql",
    var.db_engine == "aurora-mysql" ? "error" : "postgresql",
    var.db_engine == "aurora-mysql" ? "general" : "postgresql",
    var.db_engine == "aurora-mysql" ? "slowquery" : "postgresql"
  ]

  lifecycle {
    ignore_changes = [engine_mode, engine_version]
  }

  tags = var.tags
}

# RDS Aurora instances
resource "aws_rds_cluster_instance" "aurora_cluster_instance" {
  count                           = var.instance_count
  cluster_identifier              = aws_rds_cluster.aurora.id
  identifier                      = "${var.project_name}-instance-${count.index + 1}"
  instance_class                  = var.instance_type
  engine                          = var.db_engine
  publicly_accessible             = var.publicly_accessible
  monitoring_interval             = var.enable_enhanced_monitoring ? 60 : 0
  performance_insights_enabled    = var.enable_performance_insights
  performance_insights_kms_key_id = var.enable_performance_insights ? var.kms_key_arn : null
  tags                            = var.tags
}

resource "random_password" "aurora_password" {
  length           = 24
  special          = false
}

