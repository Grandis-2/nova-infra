variable "enabled" {
  description = "bastion 생성 여부. DB 작업이 필요할 때만 켜도 된다"
  type        = bool
  default     = true
}

variable "instance_type" {
  description = "인스턴스 타입. 포트포워딩만 하므로 가장 작은 타입이면 된다"
  type        = string
  default     = "t4g.nano"
}

variable "ami_id" {
  description = "AMI 를 고정하고 싶을 때 지정한다. 비우면 최신 Amazon Linux 2023(ARM)을 쓴다"
  type        = string
  default     = ""
}
