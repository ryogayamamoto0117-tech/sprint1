resource "aws_lb_target_group" "sprint6" {
  name        = "sprint6-app-tg"
  port        = 8080
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = data.aws_vpc.existing.id

  health_check {
    enabled             = true
    path                = "/health"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener_rule" "sprint6" {
  listener_arn = data.aws_lb_listener.existing.arn
  priority     = 2

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.sprint6.arn
  }

  condition {
    http_header {
      http_header_name = "X-Environment"
      values           = ["sprint6"]
    }
  }
}