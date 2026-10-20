terraform {
  backend "s3" {
    key          = "prod/rds/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
