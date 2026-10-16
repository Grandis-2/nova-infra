variable "name_prefix" {
  description = "이름 접두사(예: nova-prod). 함수 이름은 <name_prefix>-<name>"
  type        = string
}

variable "name" {
  description = "함수 이름(접두사 뒤). functions/<name> 폴더 이름과 맞춘다"
  type        = string
}

variable "description" {
  description = "함수 설명. AWS 로 가는 값이라 ASCII 만 쓴다"
  type        = string

  validation {
    condition     = can(regex("^[[:ascii:]]*$", var.description))
    error_message = "description 은 ASCII 만 쓴다."
  }
}

variable "source_dir" {
  description = "코드 폴더(functions/<name>). tests/ · __pycache__/ 는 묶지 않는다"
  type        = string
}

variable "handler" {
  description = "진입점(<파일>.<함수>)"
  type        = string
  default     = "handler.handler"
}

variable "runtime" {
  description = "Lambda 런타임"
  type        = string
  default     = "python3.13"
}

variable "memory_size" {
  description = "메모리(MiB). CPU 도 이에 비례한다"
  type        = number
  default     = 256
}

variable "timeout" {
  description = "실행 제한 시간(초)"
  type        = number
  default     = 60
}

variable "reserved_concurrency" {
  description = "동시 실행 예약(상한). -1 이면 예약하지 않는다. 계정 한도가 10 이면 예약하지 못한다(예약 안 한 몫이 10 아래로 내려갈 수 없다)"
  type        = number
  default     = -1
}

variable "environment" {
  description = "환경 변수. 비밀은 넣지 않는다(Secrets Manager 에서 읽는다)"
  type        = map(string)
  default     = {}
}

variable "subnet_ids" {
  description = "VPC 안에서 돌릴 서브넷. 비우면 VPC 밖에서 돈다"
  type        = list(string)
  default     = []
}

variable "security_group_ids" {
  description = "VPC 안에서 돌릴 때의 SG(securitygroup 스택 소유)"
  type        = list(string)
  default     = []
}

variable "policy_json" {
  description = "함수가 부르는 AWS API 권한(IAM 정책 JSON). 로그 쓰기 · VPC 연결 권한은 모듈이 넣는다"
  type        = string
  default     = ""
}

variable "log_retention_days" {
  description = "함수 로그(CloudWatch) 보관 기간(일)"
  type        = number
  default     = 14
}

variable "max_retry_attempts" {
  description = "비동기 호출(S3 이벤트 등)이 실패했을 때 다시 시도하는 횟수(0~2)"
  type        = number
  default     = 2
}

variable "alarm_topic_arn" {
  description = "실패 큐 경보를 보낼 SNS 토픽. 비우면 경보를 만들지 않는다"
  type        = string
  default     = ""
}
