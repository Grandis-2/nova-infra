# 다른 스택 output 과 서비스별 환경변수 · 시크릿.
# 클러스터는 리전에 하나이고, 태스크의 AZ 는 서비스 subnets(앱 서브넷 두 개)가 정한다.

locals {
  vpc_id          = data.terraform_remote_state.vpc.outputs.vpc_id
  public_subnets  = data.terraform_remote_state.vpc.outputs.public_subnet_ids
  app_subnets     = data.terraform_remote_state.vpc.outputs.app_subnet_ids
  alb_sg_id       = data.terraform_remote_state.security.outputs.alb_security_group_id
  app_sg_ids      = data.terraform_remote_state.security.outputs.app_security_group_ids
  exec_role_arn   = data.terraform_remote_state.iam.outputs.task_execution_role_arn
  ecs_lb_role_arn = data.terraform_remote_state.iam.outputs.ecs_lb_role_arn

  # 변수가 비면 acm 스택 인증서를 쓴다. 둘 다 없으면 HTTP 로만 뜬다
  alb_certificate_arn = var.alb_certificate_arn != "" ? var.alb_certificate_arn : data.terraform_remote_state.acm.outputs.alb_certificate_arn
  task_role_arns      = data.terraform_remote_state.iam.outputs.task_role_arns
  repository_urls     = data.terraform_remote_state.ecr.outputs.repository_urls
  repository_names    = data.terraform_remote_state.ecr.outputs.repository_names # nova/<서비스>

  # 쓰기 DB 에 바로 붙는 주소(마이그레이션 태스크). 앱은 RDS 이전 기간에 ProxySQL NLB 로 붙는다(db_via_proxysql, proxysql.tf)
  db_address            = data.terraform_remote_state.database.outputs.db_address
  db_port               = data.terraform_remote_state.database.outputs.db_port
  app_db_address        = var.db_via_proxysql ? one(aws_lb.proxysql[*].dns_name) : local.db_address
  app_db_port           = var.db_via_proxysql ? local.proxysql_port : local.db_port
  db_secret_arns        = data.terraform_remote_state.database.outputs.app_secret_arns
  app_secret_arns       = data.terraform_remote_state.secrets.outputs.app_secret_arns
  generated_secret_arns = data.terraform_remote_state.secrets.outputs.generated_secret_arns
  shared_secret_arns    = data.terraform_remote_state.secrets.outputs.shared_secret_arns

  redis_endpoints = data.terraform_remote_state.elasticache.outputs.redis_endpoints
  redis_ports     = data.terraform_remote_state.elasticache.outputs.redis_ports

  queues     = data.terraform_remote_state.sqs.outputs.queues
  log_bucket = data.terraform_remote_state.s3.outputs.log_bucket.id

  # 서비스 주소: Service Connect 별칭 <이름>.<네임스페이스>:<포트> (예: http://preorder.nova.local:8083)
  # deploy: false 서비스도 주소를 정해 둔다 (호출하는 쪽 설정이 비지 않게)
  service_urls = {
    for k, v in local.services : k => "http://${v.name}.${var.namespace_name}:${v.port}" if v.port > 0
  }

  # DB 가 인터넷 너머(NCP)에 있다. TLS 모드는 db_ssl_mode 로 정한다
  jdbc_params = "serverTimezone=UTC&characterEncoding=UTF-8&sslMode=${var.db_ssl_mode}"

  # ── 환경변수 ───────────────────────────────────────────────
  # 앱 설정은 SPRING_APPLICATION_JSON 하나로 넣는다 (config.tf). 그 외는 service.yml 의 environment
  service_env = {
    for k, v in local.deployed_services : k => merge(
      {
        SPRING_PROFILES_ACTIVE  = var.spring_profile
        AWS_REGION              = var.aws_region
        SPRING_APPLICATION_JSON = local.service_config_json[k]
      },
      local.otel_env[k], # otel.tf. service.yml 의 environment 가 같은 이름이면 그쪽이 이긴다
      v.environment,
      local.profiling_env[k], # otel.tf. 프로파일 설정은 서비스 environment 가 덮지 못하게 마지막에 둔다
    )
  }

  # ── 시크릿 ─────────────────────────────────────────────────
  # 값 대신 "시크릿 ARN:json 키::" 를 넘겨 태스크 정의에 비밀 값이 남지 않게 한다.
  #   db              → ncp-database 가 만든 서비스 계정 (nova-prod/db/app/<서비스>)
  #   extra_databases → 같은 계정으로 접속하는 다른 DB
  #   secrets.sops.yml  → 그 서비스의 시크릿(nova-prod/app/<서비스>). 키 이름이 곧 환경변수 이름
  #   generated_secrets → Terraform 이 만든 시크릿 (값 전체가 환경변수 값). shared/<이름> 은 공유 시크릿
  service_secrets = {
    for k, v in local.deployed_services : k => merge(
      v.db != null ? {
        SPRING_DATASOURCE_USERNAME = "${local.db_secret_arns[k]}:username::"
        SPRING_DATASOURCE_PASSWORD = "${local.db_secret_arns[k]}:password::"
      } : {},
      {
        for pair in flatten([
          for db, prefix in v.extra_databases : [
            { env = "${upper(replace(replace(prefix, "-", ""), ".", "_"))}_USERNAME", ref = "${local.db_secret_arns[k]}:username::" },
            { env = "${upper(replace(replace(prefix, "-", ""), ".", "_"))}_PASSWORD", ref = "${local.db_secret_arns[k]}:password::" },
          ]
        ]) : pair.env => pair.ref
      },
      # 시크릿이 아직 없으면 빈 ARN 으로 두고 config.tf 의 precondition 이 원인을 알려 준다
      { for key in lookup(local.secret_keys, k, []) : key => "${lookup(local.app_secret_arns, k, "")}:${key}::" },
      {
        for e, t in v.generated_secrets : e => (
          startswith(t, "shared/") ? lookup(local.shared_secret_arns, trimprefix(t, "shared/"), "") : lookup(local.generated_secret_arns, "${k}/${e}", "")
        )
      },
    )
  }
}
