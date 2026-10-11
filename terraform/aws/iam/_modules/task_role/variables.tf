variable "name_prefix" {
  type = string
}

variable "name" {
  description = "서비스 이름 (service.yml 의 name)"
  type        = string
}

variable "assume_role_policy" {
  description = "ECS 태스크가 이 역할을 빌리는 신뢰 정책 (JSON)"
  type        = string
}

variable "log_group_arn" {
  description = "로그를 쓸 수 있는 로그 그룹 ARN (와일드카드 가능)"
  type        = string
}

variable "send_queue_arns" {
  description = "메시지를 보낼 큐"
  type        = list(string)
  default     = []
}

variable "consume_queue_arns" {
  description = "메시지를 받아 지울 큐"
  type        = list(string)
  default     = []
}

variable "dlq_arns" {
  description = "들여다보고 메시지를 옮길 DLQ"
  type        = list(string)
  default     = []
}

variable "upload_bucket_arn" {
  description = "이미지 업로드 버킷. uploads 가 true 일 때만 권한을 준다"
  type        = string
}

variable "uploads" {
  description = "업로드 버킷에 쓸 수 있는지 (presigned URL 서명)"
  type        = bool
  default     = false
}
