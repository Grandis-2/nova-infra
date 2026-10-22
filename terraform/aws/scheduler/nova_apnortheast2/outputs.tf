output "schedule_names" {
  description = "서비스 키 -> 스케줄 이름"
  value       = { for k, s in aws_scheduler_schedule.this : k => s.name }
}

output "schedule_group_name" {
  value = aws_scheduler_schedule_group.this.name
}
