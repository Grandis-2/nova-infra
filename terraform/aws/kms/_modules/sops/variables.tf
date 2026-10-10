variable "region" {
  type = string
}

variable "common_alias" {
  description = "common 키 별칭 (alias/ 제외)"
  type        = string
}

variable "secure_alias" {
  description = "secure 키 별칭 (alias/ 제외)"
  type        = string
}

variable "role_name_prefix" {
  description = "sops 역할 이름 접두사. Terraform 역할은 <product>-* 이름만 관리할 수 있다"
  type        = string
}
