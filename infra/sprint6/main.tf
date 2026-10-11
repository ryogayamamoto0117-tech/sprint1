resource "aws_cloudwatch_log_group" "sprint6" {
  name              = "/ecs/sprint6-app"
  retention_in_days = 14
}