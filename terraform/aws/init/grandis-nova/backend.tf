# 버킷이 생기기 전에는 쓸 수 없다. 첫 apply 는 로컬 상태로 하고 init -migrate-state 로 옮긴다.
terraform {
  backend "s3" {
    key          = "prod/init/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
