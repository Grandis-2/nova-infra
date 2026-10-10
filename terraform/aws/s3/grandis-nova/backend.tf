terraform {
  backend "s3" {
    key          = "prod/s3/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
