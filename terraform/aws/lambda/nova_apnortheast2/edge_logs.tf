# ALB · CloudFront 접근 로그 → OTel 게이트웨이 → Loki
# 부하 시험 요청 줄(User-Agent nova-loadtest/)은 보내지 않는다. k6 결과와 겹치고, 시험 중에는 Loki 수집 한도를 넘긴다.
# 로그 버킷에 파일이 생기면(몇 분 늦게, 하루 약 450개) S3 이벤트로 돈다.
# 게이트웨이를 거치는 이유: 마스킹을 한 곳에서 하고, obs 가 재배포되는 동안 게이트웨이 큐가 데이터를 들고 있는다.

module "edge_logs" {
  source = "../_modules/function"

  name_prefix = local.name_prefix
  name        = "edge-logs"
  description = "Ship ALB and CloudFront access logs from S3 to the OTel gateway (Loki)"
  source_dir  = "${local.functions_root}/edge-logs"

  # 파일을 1MiB 씩 읽어 줄 단위로 처리하고 묶음 500줄씩 보낸다. 메모리는 파일 크기와 상관없다.
  # 평소 파일은 수백 KB 지만 부하 시험 때는 ALB 노드 하나의 5분 파일이 수십만 줄이다. 시험 줄(User-Agent nova-loadtest/)은
  # 보내지 않아도 압축을 풀고 읽어야 하므로 시간 제한을 넉넉히 둔다(로컬에서 30만 줄 1.4초, Lambda 256MB 는 CPU 가 작다)
  memory_size = 256
  timeout     = 300

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
