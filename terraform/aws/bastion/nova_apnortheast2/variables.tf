variable "enabled" {
  description = "bastion 생성 여부. DB 작업이 필요할 때만 켜도 된다"
  type        = bool
  default     = true
}

variable "instance_type" {
  description = "인스턴스 타입. 평소에는 포트포워딩만 하므로 가장 작은 타입이면 된다. RDS 이전 기간에는 런북(MySQL Shell 덤프)을 돌려 키운다"
  type        = string
  default     = "t4g.nano"
}

variable "ami_id" {
  description = "AMI 를 고정하고 싶을 때 지정한다. 비우면 최신 Amazon Linux 2023(ARM)을 쓴다"
  type        = string
  default     = ""
}

variable "root_volume_size" {
  description = "루트 볼륨(GiB). RDS 이전 기간에는 덤프 파일을 여기 둔다"
  type        = number
  default     = 8
}

variable "db_migration_tools" {
  description = "RDS 이전 런북 도구(MySQL 8.4 클라이언트 · MySQL Shell · jq)를 깐다. 바꾸면 인스턴스를 새로 만든다(상태 없음)"
  type        = bool
  default     = false
}

variable "db_migration_runbook" {
  description = "scripts/db-migration 단계를 SSM 문서로 등록한다 (db_migration.tf). rds 스택과 런북 스크립트가 있어야 한다"
  type        = bool
  default     = false
}
