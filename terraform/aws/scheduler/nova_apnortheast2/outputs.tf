output "schedule_names" {
  value = { for k, s in aws_scheduler_schedule.job : k => s.name }
}

output "schedule_group_name" {
  value = aws_scheduler_schedule_group.this.name
}
