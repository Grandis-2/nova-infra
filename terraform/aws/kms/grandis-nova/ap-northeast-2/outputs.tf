output "sops_key_arns" {
  value = module.sops_grandis_nova.key_arns
}

output "sops_role_arns" {
  description = "common, secure 역할. atlantis-deploy 가 태스크 역할에 assume 권한을 준다"
  value       = module.sops_grandis_nova.role_arns
}

output "sops_kms" {
  description = ".sops.yaml creation_rules 의 kms 값"
  value       = module.sops_grandis_nova.sops_kms
}
