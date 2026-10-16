output "edge_logs_function_name" {
  description = "엣지 접근 로그를 Loki 로 보내는 함수(NV-542)"
  value       = module.edge_logs.function_name
}
