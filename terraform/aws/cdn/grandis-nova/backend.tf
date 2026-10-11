terraform {
  backend "s3" {
    key          = "prod/cdn/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
