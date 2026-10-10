output "key_arns" {
  description = "common, secure -> KMS 키 ARN"
  value       = { for k, v in aws_kms_key.sops : k => v.arn }
}

output "role_arns" {
  description = "common, secure -> sops 역할 ARN"
  value       = { for k, v in aws_iam_role.sops : k => v.arn }
}

output "sops_kms" {
  description = ".sops.yaml 의 kms 값 (<키 ARN>+<역할 ARN>)"
  value       = { for k in keys(aws_kms_key.sops) : k => "${aws_kms_key.sops[k].arn}+${aws_iam_role.sops[k].arn}" }
}
