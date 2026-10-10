# Atlantis 비밀도 이 키로 암호화하므로 Atlantis 보다 먼저 관리자가 apply 한다
terraform {
  backend "s3" {
    key          = "prod/sops/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
