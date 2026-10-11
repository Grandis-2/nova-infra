terraform {
  backend "s3" {
    key          = "prod/bastion/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
