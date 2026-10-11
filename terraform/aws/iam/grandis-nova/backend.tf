terraform {
  backend "s3" {
    key          = "prod/iam/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
