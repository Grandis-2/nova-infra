terraform {
  backend "s3" {
    key          = "prod/acm/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
