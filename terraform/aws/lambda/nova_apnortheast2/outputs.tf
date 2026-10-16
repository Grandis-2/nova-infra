output "edge_logs_function_name" {
  description = "엣지 접근 로그를 Loki 로 보내는 함수"
  value       = module.edge_logs.function_name
}

output "edge_logs_failed_queue_url" {
  description = "엣지 로그 함수가 재시도까지 실패한 이벤트(다시 보내는 방법은 ../README.md)"
  value       = module.edge_logs.failed_queue_url
}
