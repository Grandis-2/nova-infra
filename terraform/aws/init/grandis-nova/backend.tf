# 버킷이 생기기 전에는 쓸 수 없다. 새 계정에서 처음 만들 때만 관리자 세션으로 한다.
#   1) 이 파일을 잠시 다른 이름으로 바꾸고 terraform init && terraform apply (로컬 상태로 버킷 생성)
#   2) 이 파일을 되돌리고 terraform init -migrate-state -backend-config=bucket=<버킷> -backend-config=region=ap-northeast-2
#   3) S3 에 prod/init/terraform.tfstate 가 생겼는지 확인한 뒤 로컬 terraform.tfstate 를 지운다
terraform {
  backend "s3" {
    key          = "prod/init/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
