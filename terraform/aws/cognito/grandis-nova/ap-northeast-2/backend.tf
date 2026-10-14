terraform {
  backend "s3" {
    key          = "prod/cognito/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
