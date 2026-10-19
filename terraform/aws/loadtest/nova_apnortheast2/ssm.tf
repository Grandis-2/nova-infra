# nova-loadtest 워크플로가 읽어 컨트롤러에 넘기는 값. nova-loadtest 는 공개 저장소라 ID 를 거기 적지 않고 여기 둔다.
# 키 이름과 형식은 nova-loadtest 와 맞춘 약속이라 바꾸면 그쪽도 같이 바꾼다.
# 비밀이 아니므로 plan 에서 보이게 insecure_value 로 둔다.

# 시험 리소스
#   tasks.<이름>  taskDefinition 은 패밀리(최신 개정판이 뜬다), container 는 containerOverrides 의 name,
#                 subnets · securityGroups · assignPublicIp 는 awsvpcConfiguration 에 그대로. k6 만 public 서브넷 · 공인 IP
#                 (NAT 가 t4g.micro 라 부하와 이미지 내려받기가 NAT 를 지나면 NAT 가 먼저 막힌다)
resource "aws_ssm_parameter" "run_task" {
  name = "/${local.name_prefix}/loadtest/run-task"
  type = "String"
  insecure_value = jsonencode({
    cluster = aws_ecs_cluster.loadtest.name
    bucket  = aws_s3_bucket.loadtest.id
    tasks = {
      for k, t in local.tasks : k => {
        taskDefinition = aws_ecs_task_definition.task[k].family
        container      = t.container
        subnets        = k == "k6" ? local.public_subnets : local.app_subnets
        securityGroups = [aws_security_group.task[t.task_role].id]
        assignPublicIp = k == "k6" ? "ENABLED" : "DISABLED"
      }
    }
  })

  tags = { Name = local.loadtest_name }
}

# 관측 쪽 값
#   otlpEndpoint  스킴 없는 host:port. k6 의 K6_OTEL_HTTP_EXPORTER_ENDPOINT 에 그대로 넣는다(평문 HTTP 라 INSECURE=true 와 같이)
#   mimir         고정 주소가 없다(obs 가 다시 뜨면 IP 가 바뀐다). 컨트롤러가 이 클러스터 · 서비스의 RUNNING 태스크를 찾아
#                 ENI 의 사설 IP 로 http://<IP>:<port><queryPath> 를 조회한다. 여럿이면 가장 늦게 시작한 것
locals {
  gateway_ingest_endpoint = data.terraform_remote_state.lgtm.outputs.gateway_ingest_endpoint
}

resource "aws_ssm_parameter" "observability" {
  name = "/${local.name_prefix}/loadtest/observability"
  type = "String"
  insecure_value = jsonencode({
    otlpEndpoint = trimprefix(local.gateway_ingest_endpoint, "http://")
    mimir = {
      cluster   = data.terraform_remote_state.ecs.outputs.observability_cluster_name
      service   = data.terraform_remote_state.lgtm.outputs.obs_service_name
      port      = 9009
      queryPath = "/prometheus/api/v1/query"
    }
  })

  tags = { Name = local.loadtest_name }

  lifecycle {
    # 게이트웨이를 끈 설정(lgtm gateway_enabled = false)이면 수집 주소가 빈 값이다
    precondition {
      condition     = startswith(local.gateway_ingest_endpoint, "http://")
      error_message = "lgtm 의 gateway_ingest_endpoint 가 비었거나 http:// 가 아닙니다(게이트웨이를 껐나요?). k6 가 지표를 보낼 곳이 없습니다."
    }
  }
}
