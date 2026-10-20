# RDS 이전 런북 — scripts/db-migration 의 단계를 SSM 문서로 등록한다.
# 운영자 노트북이 아니라 bastion 에서 돌려(aws ssm send-command) 세션이 끊겨도 단계가 끝까지 간다.
#
#   aws ssm send-command --document-name nova-prod-db-migration-60-cutover \
#     --instance-ids <bastion_instance_id> --parameters 'Args=""' --cloud-watch-output-config CloudWatchOutputEnabled=true
#
# 문서는 lib.sh 와 그 단계 스크립트를 함께 싣고, 접속 정보는 실행할 때 인스턴스 역할(iam 스택 db_migration.tf)로 읽는다.
# 비밀은 문서 매개변수로 넘기지 않는다(명령 기록에 남는다). 스크립트를 고치면 이 스택을 다시 apply 해야 문서가 바뀐다.
# 문서 하나는 64KB 까지라 lib.sh 가 크게 늘면 나눠야 한다.

locals {
  runbook_dir = "${path.module}/../../../../scripts/db-migration"
  runbook_steps = var.db_migration_runbook ? {
    for f in fileset(local.runbook_dir, "[0-9][0-9]-*.sh") : trimsuffix(f, ".sh") => f
  } : {}
}

# 리허설 · 운영 RDS 주소와 마스터 비밀, 쓰기 대상 · 덤프 위치 파라미터
data "terraform_remote_state" "rds" {
  count = var.db_migration_runbook ? 1 : 0

  backend = "s3"
  config  = merge(local.remote_state_defaults, { key = "${var.env}/rds/terraform.tfstate" })
}

resource "aws_ssm_document" "runbook" {
  for_each = local.runbook_steps

  name            = "${local.name_prefix}-db-migration-${each.key}"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "RDS migration runbook step ${each.key} (scripts/db-migration/${each.value})"
    parameters = {
      Args = {
        type           = "String"
        description    = "Arguments for the step (g2 | start | status | stop | resume | reset | compare for 40-replication, recover for 60 and 70, setup | teardown | clean-rds for 50). Prefix with 'rehearsal <rehearsal NCP domain>' to run against the rehearsal group (rehearsal NCP + the still-empty production RDS)"
        default        = ""
        allowedPattern = "^[a-z0-9 ._=-]*$" # 셸에 그대로 들어가므로 영문 소문자 · 숫자 · 공백 . _ = - 만 받는다
      }
    }
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "run"
      inputs = {
        timeoutSeconds = "3600"
        runCommand = split("\n", templatefile("${path.module}/templates/runbook.sh.tftpl", {
          region                = var.aws_region
          name_prefix           = local.name_prefix
          script                = each.value
          lib_b64               = filebase64("${local.runbook_dir}/lib.sh")
          script_b64            = filebase64("${local.runbook_dir}/${each.value}")
          ncp_address           = data.terraform_remote_state.rds[0].outputs.ncp_address
          ncp_port              = 3306
          rds_address           = data.terraform_remote_state.rds[0].outputs.rds_address
          rds_port              = data.terraform_remote_state.rds[0].outputs.rds_port
          rds_master_secret_arn = data.terraform_remote_state.rds[0].outputs.rds_master_secret_arn
          app_secret_arns       = join(" ", values(data.terraform_remote_state.rds[0].outputs.app_secret_arns))
          writer_param          = data.terraform_remote_state.rds[0].outputs.writer_parameter.name
          coords_param          = data.terraform_remote_state.rds[0].outputs.dump_coords_parameter.name
          proxysql_param        = "/${local.name_prefix}/db-migration/proxysql"
          args                  = "{{ Args }}"
        }))
      }
    }]
  })

  tags = { Name = "${local.name_prefix}-db-migration-${each.key}" }
}
