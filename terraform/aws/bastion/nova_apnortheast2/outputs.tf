output "bastion_instance_id" {
  description = "aws ssm start-session --target 에 넣는 값"
  value       = var.enabled ? aws_instance.this[0].id : ""
}
