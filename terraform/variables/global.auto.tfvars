# 모든 스택이 공유하는 값 (각 스택 디렉터리에 심볼릭 링크). 비밀이 아니므로 커밋한다.
# *.auto.tfvars 가 TF_VAR_* 보다 우선하므로 여기 있는 값은 환경변수로 덮어쓸 수 없다.
# 실행 주체(assume_role_arn, terraform_actor)는 여기 두지 않고 TF_VAR_* 로 넣는다.

product            = "nova"
env                = "prod"
aws_region         = "ap-northeast-2"
availability_zones = ["ap-northeast-2a", "ap-northeast-2c"]

# 상태 버킷. S3 버킷 이름은 전역에서 유일해야 한다.
# atlantis-deploy 저장소의 terraform.tfvars 에 있는 버킷 이름과 같아야 한다.
tfstate_bucket = "grandis-nova-prod-apnortheast2-tfstate"
