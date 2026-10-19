terraform {
  backend "s3" {
    key          = "prod/loadtest/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
