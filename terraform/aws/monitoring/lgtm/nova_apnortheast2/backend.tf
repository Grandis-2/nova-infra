terraform {
  backend "s3" {
    key          = "prod/lgtm/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
