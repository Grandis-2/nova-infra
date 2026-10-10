terraform {
  backend "s3" {
    key          = "prod/elasticache/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
