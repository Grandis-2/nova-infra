terraform {
  backend "s3" {
    key          = "prod/ecs/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
