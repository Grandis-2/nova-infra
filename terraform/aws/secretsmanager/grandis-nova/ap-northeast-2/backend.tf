terraform {
  backend "s3" {
    key          = "prod/secrets/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
