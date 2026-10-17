
terraform {
  backend "s3" {
    bucket       = "terraform-state-237575223564-ap-northeast-1"
    key          = "project-nexus/sprint6/terraform.tfstate"
    region       = "ap-northeast-1"
    encrypt      = true
    use_lockfile = true
  }
}
