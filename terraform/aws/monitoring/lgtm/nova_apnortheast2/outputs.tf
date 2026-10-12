output "obs_service_name" {
  description = "관측 스택 ECS 서비스. Grafana 접속은 이 서비스 태스크에 ECS Exec 포트 포워딩"
  value       = aws_ecs_service.obs.name
}
