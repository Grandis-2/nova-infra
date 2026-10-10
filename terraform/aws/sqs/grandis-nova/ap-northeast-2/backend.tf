terraform {
  backend "s3" {
    key          = "prod/sqs/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
