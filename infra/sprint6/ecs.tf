resource "aws_ecs_task_definition" "sprint6" {
  family                   = "sprint6-app"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"

  cpu    = "256"
  memory = "512"

  execution_role_arn = aws_iam_role.ecs_task_execution.arn

  container_definitions = jsonencode([
    {
      name  = "sprint6-app"
      image = "237575223564.dkr.ecr.ap-northeast-1.amazonaws.com/sprint4-app:7cb0cad8ede49e6b2b95aeb0976252b7708dc49d"

      essential = true

      portMappings = [
        {
          containerPort = 8080
          protocol      = "tcp"
        }
      ]

      environment = [
        {
          name  = "DB_HOST"
          value = "sprint2-postgres.c7y2kowyu6ih.ap-northeast-1.rds.amazonaws.com"
        },
        {
          name  = "DB_PORT"
          value = "5432"
        },
        {
          name  = "DB_NAME"
          value = "sprint2db"
        },
        {
          name  = "DB_USER"
          value = "postgres"
        }
      ]
      secrets = [
        {
          name      = "DB_PASSWORD"
          valueFrom = "/sprint3/db/password"
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"

        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.sprint6.name
          "awslogs-region"        = "ap-northeast-1"
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])
}

resource "aws_ecs_cluster" "sprint6" {
  name = "sprint6-ecs-cluster"
}

resource "aws_ecs_service" "sprint6" {
  name            = "sprint6-app-service"
  cluster         = aws_ecs_cluster.sprint6.arn
  task_definition = aws_ecs_task_definition.sprint6.arn
  launch_type     = "FARGATE"
  desired_count   = 0

  network_configuration {
    subnets = [
      data.aws_subnet.public_a.id,
      data.aws_subnet.public_c.id
    ]

    security_groups = [
      aws_security_group.fargate.id
    ]

    assign_public_ip = true
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.sprint6.arn
    container_name   = "sprint6-app"
    container_port   = 8080
  }
}