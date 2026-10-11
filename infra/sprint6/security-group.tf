resource "aws_security_group" "fargate" {
  name        = "sprint6-fargate-sg"
  description = "security group for Sprint 6 Fargate tasks"
  vpc_id      = data.aws_vpc.existing.id

  tags = {
    Name = "sprint6-fargate-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_to_fargate" {
  security_group_id            = aws_security_group.fargate.id
  referenced_security_group_id = data.aws_security_group.alb.id

  ip_protocol = "tcp"
  from_port   = 8080
  to_port     = 8080

  description = "Allow ALB to access Sprint 6 Fargate tasks"
}

resource "aws_vpc_security_group_egress_rule" "fargate_outbound" {
  security_group_id = aws_security_group.fargate.id

  ip_protocol = "-1"
  cidr_ipv4   = "0.0.0.0/0"

  description = "Allow outbound traffic from Sprint 6 Fargate tasks"
}

resource "aws_vpc_security_group_ingress_rule" "fargate_to_rds" {
  security_group_id            = data.aws_security_group.rds.id
  referenced_security_group_id = aws_security_group.fargate.id

  ip_protocol = "tcp"
  from_port   = 5432
  to_port     = 5432

  description = "Allow Sprint 6 Fargate tasks to access PostgreSQL"
}