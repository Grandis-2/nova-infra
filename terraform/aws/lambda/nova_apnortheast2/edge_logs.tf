# 엣지 접근 로그 → Loki (NV-542)
#
#   ALB · CloudFront 가 로그 버킷에 파일을 쓴다(몇 분 늦게, 하루 약 450개)
#     ▶ S3 이벤트 ▶ 이 함수(VPC 안) ▶ OTel 게이트웨이 otel-ingest.<네임스페이스>:4318 (OTLP HTTP)
#     ▶ 마스킹 · 리소스 허용 목록 ▶ Loki (service_name = alb · cloudfront)
#
# 무엇을 남기고 버리는지는 functions/edge-logs/handler.py 머리말에 있다.
# 게이트웨이를 쓰는 이유: 마스킹을 한 곳에서 하고, obs 가 재배포되는 동안 게이트웨이 큐가 버틴다.
# 실패하면 2번 다시 시도하고 오류 경보를 낸다. 원본 파일은 로그 버킷에 남는다.

module "edge_logs" {
  source = "../_modules/function"

  name_prefix = local.name_prefix
  name        = "edge-logs"
  description = "Ship ALB and CloudFront access logs from S3 to the OTel gateway (Loki)"
  source_dir  = "${local.functions_root}/edge-logs"

  # 파일 하나가 수백 KB 를 넘지 않는다. 묶음 500줄씩 보낸다
  memory_size = 256
  timeout     = 60

  environment = {
    OTLP_ENDPOINT          = data.terraform_remote_state.lgtm.outputs.gateway_ingest_endpoint
    DEPLOYMENT_ENVIRONMENT = var.env
    BATCH_SIZE             = "500"
  }

  # otel-ingest 이름은 VPC 의 private DNS 에서만 풀린다
  subnet_ids         = local.app_subnet_ids
  security_group_ids = [data.terraform_remote_state.security.outputs.edge_logs_security_group_id]

  policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "ReadAccessLogs"
      Effect   = "Allow"
      Action   = "s3:GetObject"
      Resource = [for p in local.edge_log_prefixes : "${local.log_bucket.arn}/${p}*"]
    }]
  })

  alarm_topic_arn = local.alerts_topic
}

locals {
  # 로그 버킷 안의 접두사(ecs 스택 alb.tf · edge 스택 logging_config). cloudfront-grafana/ 는 운영 도구라 넣지 않는다
  edge_log_prefixes = ["alb/", "cloudfront/"]
}
