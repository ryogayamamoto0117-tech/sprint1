data "aws_vpc" "existing" {
  id = "vpc-0f907ac22a8b7899a"
}

data "aws_security_group" "alb" {
  id = "sg-0d3ccb6fb13df2309"
}

data "aws_security_group" "rds" {
  id = "sg-0caee68876e3947cc"
}

data "aws_subnet" "public_a" {
  id = "subnet-055fdea94553f1c05"
}

data "aws_subnet" "public_c" {
  id = "subnet-0ff9c36a6659e052d"
}

data "aws_lb_listener" "existing" {
  arn = "arn:aws:elasticloadbalancing:ap-northeast-1:237575223564:listener/app/sprint3-alb/c2325d1f6dd1d305/154e5512925da50d"
}