#########################################
# Locals / Random suffix
#########################################

locals {
  name = var.project_name
}

resource "random_pet" "suffix" {}

#########################################
# VPC + Subnets
#########################################

data "aws_availability_zones" "available" {}

resource "aws_vpc" "this" {
  cidr_block = var.vpc_cidr
  tags       = { Name = "${local.name}-vpc" }
}

resource "aws_subnet" "public" {
  count                   = length(var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  map_public_ip_on_launch = true
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  tags                    = { Name = "${local.name}-public-${count.index}" }
}

resource "aws_subnet" "private" {
  count             = length(var.private_subnet_cidrs)
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags              = { Name = "${local.name}-private-${count.index}" }
}

#########################################
# IGW + Routing
#########################################

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${local.name}-igw" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "${local.name}-public-rt" }
}

resource "aws_route_table_association" "public_assoc" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

#########################################
# NAT Gateway
#########################################

resource "aws_eip" "nat" {
  domain = "vpc"
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
}

resource "aws_route_table_association" "private_assoc" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

#########################################
# S3 for uploads
#########################################

resource "aws_s3_bucket" "uploads" {
  bucket        = "${local.name}-uploads-${random_pet.suffix.id}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "uploads" {
  bucket                  = aws_s3_bucket.uploads.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

#########################################
# ECR
#########################################

resource "aws_ecr_repository" "repo" {
  name                 = local.name
  image_tag_mutability = "MUTABLE"
}

#########################################
# IAM Roles (task + execution)
#########################################

data "aws_iam_policy_document" "ecs_task_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_task_role" {
  name               = "${local.name}-ecs-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume.json
}

data "aws_iam_policy_document" "ecs_task_policy" {
  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject", "s3:PutObject", "s3:ListBucket", "s3:DeleteObject"
    ]
    resources = [
      aws_s3_bucket.uploads.arn,
      "${aws_s3_bucket.uploads.arn}/*"
    ]
  }

  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "ecs_task_policy_attach" {
  role   = aws_iam_role.ecs_task_role.id
  policy = data.aws_iam_policy_document.ecs_task_policy.json
}

#########################################
# Execution role
#########################################

resource "aws_iam_role" "ecs_exec_role" {
  name               = "${local.name}-exec-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume.json
}

resource "aws_iam_role_policy_attachment" "ecs_exec_attach" {
  role       = aws_iam_role.ecs_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

#########################################
# ALB
#########################################

resource "aws_lb" "alb" {
  name               = "${local.name}-alb"
  internal           = false
  load_balancer_type = "application"
  subnets            = aws_subnet.public[*].id
}

resource "aws_security_group" "alb_sg" {
  name   = "${local.name}-alb-sg"
  vpc_id = aws_vpc.this.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_lb_target_group" "tg" {
  name        = "${local.name}-tg"
  port        = 1337
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.this.id
  health_check {
    path = "/_health"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg.arn
  }
}

#########################################
# Security groups
#########################################

resource "aws_security_group" "ecs_sg" {
  name   = "${local.name}-ecs-sg"
  vpc_id = aws_vpc.this.id

  ingress {
    from_port       = 1337
    to_port         = 1337
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "rds_sg" {
  name   = "${local.name}-rds-sg"
  vpc_id = aws_vpc.this.id

  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

#########################################
# RDS MySQL
#########################################

resource "aws_db_subnet_group" "db_subnets" {
  name       = "${local.name}-db-subnet-group"
  subnet_ids = aws_subnet.private[*].id
}

resource "random_password" "db" {
  length  = 16
  special = false
}


resource "aws_db_instance" "mysql" {
  identifier        = "${local.name}-mysql"
  allocated_storage    = 20

  engine               = "mysql"
  engine_version       = "8.0"  # change to available version
  instance_class       = "db.t4g.micro"
  
  db_name  = "strapi"
  username = var.db_username
  password = var.db_password == null ? random_password.db.result : var.db_password

  db_subnet_group_name   = aws_db_subnet_group.db_subnets.name
  vpc_security_group_ids = [aws_security_group.rds_sg.id]

  skip_final_snapshot = true
  publicly_accessible = false
}


#########################################
# Secrets Manager
#########################################

resource "aws_secretsmanager_secret" "db_secret" {
  name = "${local.name}-mysql-secret-${random_pet.suffix.id}"
}


resource "aws_secretsmanager_secret_version" "db_secret_value" {
  secret_id = aws_secretsmanager_secret.db_secret.id

  secret_string = jsonencode({
    host     = aws_db_instance.mysql.address
    port     = aws_db_instance.mysql.port
    username = var.db_username
    password = var.db_password == null ? random_password.db.result : var.db_password
    database = "strapi"
  })
}

#########################################
# ECS Cluster
#########################################

resource "aws_ecs_cluster" "this" {
  name = "${local.name}-cluster"
}

#########################################
# Task Definition (MySQL env)
#########################################

resource "aws_ecs_task_definition" "strapi" {
  family                   = "${local.name}-task"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 512
  memory                   = 1024
  execution_role_arn       = aws_iam_role.ecs_exec_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn

  container_definitions = jsonencode([{
    name  = "strapi"
    image = "${aws_ecr_repository.repo.repository_url}:latest"

    portMappings = [{
      containerPort = 1337
      hostPort      = 1337
    }]

    environment = [
      { name = "DATABASE_CLIENT", value = "mysql" },
      { name = "DATABASE_HOST", value = aws_db_instance.mysql.address },
      { name = "DATABASE_PORT", value = tostring(aws_db_instance.mysql.port) },
      { name = "DATABASE_NAME", value = "strapi" },
      { name = "DATABASE_USERNAME", value = var.db_username }
    ]

    secrets = [
      {
        name      = "DATABASE_PASSWORD"
        valueFrom = aws_secretsmanager_secret.db_secret.arn
      }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-region"        = var.aws_region
        "awslogs-group"         = "/ecs/${local.name}"
        "awslogs-stream-prefix" = "strapi"
      }
    }
  }])
}

resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/${local.name}"
  retention_in_days = 14
}

#########################################
# ECS Service
#########################################

resource "aws_ecs_service" "strapi" {
  name            = "${local.name}-service"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.strapi.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.ecs_sg.id]
    assign_public_ip = false
  }

  load_balancer {
    container_name   = "strapi"
    container_port   = 1337
    target_group_arn = aws_lb_target_group.tg.arn
  }

  depends_on = [aws_lb_listener.http]
}

#########################################
# Outputs
#########################################

# output "alb_dns" {
#   value = aws_lb.alb.dns_name
# }

# output "mysql_endpoint" {
#   value = aws_db_instance.mysql.address
# }

# output "ecr_repo" {
#   value = aws_ecr_repository.repo.repository_url
# }

# output "s3_bucket" {
#   value = aws_s3_bucket.uploads.bucket
# }
