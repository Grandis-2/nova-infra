terraform {
  backend "s3" {
    key          = "prod/monitoring/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
