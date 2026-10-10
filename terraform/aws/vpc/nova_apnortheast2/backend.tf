terraform {
  backend "s3" {
    key          = "prod/vpc/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
