terraform {
  backend "s3" {
    key          = "prod/ecr/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
