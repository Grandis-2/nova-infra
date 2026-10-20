data "terraform_remote_state" "vpc" {
  backend = "s3"
  config  = local.remote_state.vpc
}

data "terraform_remote_state" "security" {
  backend = "s3"
  config  = local.remote_state.securitygroup
}

# NCP DB 스택. 출력 6개를 같은 이름으로 다시 내보낸다(outputs.tf).
# 공용 매핑(local.remote_state.database)은 전환 뒤 소비자가 이 스택을 보도록 바꿀 수 있어, 여기서는 NCP 상태 키를 직접 쓴다
# (공용 매핑을 쓰면 그때 이 스택이 자기 출력을 읽어 ncp_address 가 RDS 주소로 바뀐다)
data "terraform_remote_state" "database" {
  backend = "s3"
  config  = merge(local.remote_state_defaults, { key = "${var.env}/database/terraform.tfstate" })
}
