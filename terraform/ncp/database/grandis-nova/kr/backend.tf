terraform {
  backend "s3" {
    key          = "prod/database/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
