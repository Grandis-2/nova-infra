terraform {
  backend "s3" {
    key          = "prod/security/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
