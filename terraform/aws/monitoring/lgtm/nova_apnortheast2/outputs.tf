output "obs_service_name" {
  description = "관측 스택 ECS 서비스. Grafana 접속은 이 서비스 태스크에 ECS Exec 포트 포워딩"
  value       = local.obs_name
}

output "gateway_ingest_endpoint" {
  description = "ECS 밖(VPC 안 Lambda 등)에서 OTLP HTTP 로 보내는 게이트웨이 주소. 송신자 SG 를 게이트웨이 SG 4318 에 열어야 한다"
  value       = local.gateway_enabled ? "http://${aws_service_discovery_service.gateway_ingest[0].name}.${local.gateway_namespace}:${local.obs_ports.otlp_http}" : ""
}
