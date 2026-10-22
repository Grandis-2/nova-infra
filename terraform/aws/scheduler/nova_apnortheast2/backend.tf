terraform {
  backend "s3" {
    key          = "prod/scheduler/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
