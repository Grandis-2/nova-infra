terraform {
  backend "s3" {
    key          = "prod/edge/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
