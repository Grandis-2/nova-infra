# 런북(scripts/db-migration)과 ProxySQL 이 함께 보는 값. 값은 런북이 쓰고, Terraform 은 처음 값만 넣는다(ignore_changes).
#
#   writer       현재 쓰기 대상 ncp | rds. ProxySQL 태스크가 시작할 때 읽어 그 서버만 ONLINE 으로 둔다(ecs 스택 proxysql.tf).
#                전환 · 되돌리기가 도는 동안 런북이 switching-rds · switching-ncp 로 둔다. 그사이 새로 뜨는 태스크는 설정을 만들지 못해 트래픽을
#                받지 않는다. 끝나면 런북이 실제 쓰기 대상으로 쓴다
#   dump-coords  덤프 때의 binlog 위치 · GTID 집합(30-dump-load 가 쓰고 40 · 60 이 읽는다). 덤프와 전환 사이가
#                몇 주일 수 있어 bastion 디스크가 아니라 여기 둔다
#
# 이 스택에 두는 까닭: ecs(층 5)의 ProxySQL 이 뜨기 전에 있어야 하고, 이전이 끝나면 RDS 와 함께 정리한다.
# Terraform 이 값을 다시 쓰면 런북이 쓴 쓰기 대상이 되돌아가므로 값은 절대 Terraform 으로 바꾸지 않는다.
resource "aws_ssm_parameter" "writer" {
  name            = "/${local.name_prefix}/db-migration/writer"
  description     = "Current DB write target for ProxySQL (ncp | rds, switching-<to> during cutover). Owned by the runbook after creation"
  type            = "String"
  insecure_value  = "ncp"
  allowed_pattern = "^(ncp|rds|switching-ncp|switching-rds)$"

  lifecycle {
    ignore_changes = [insecure_value]
  }
}

resource "aws_ssm_parameter" "dump_coords" {
  name           = "/${local.name_prefix}/db-migration/dump-coords"
  description    = "binlog position and GTID set of the NCP dump. Written by the runbook (30-dump-load)"
  type           = "String"
  insecure_value = "-" # 빈 값은 넣을 수 없다. 런북(coords_load)은 이 값을 형식 오류로 보고 멈춘다(30 을 먼저 돌린다)

  lifecycle {
    ignore_changes = [insecure_value]
  }
}

# primary(Flyway · exporter, 앱이 ProxySQL 없이 붙을 때의 주소)는 런북이 쓴 실제 쓰기 대상과 같아야 한다. 다르면 두 DB 에
# 쓰기가 갈린다(전환 · 되돌리기 뒤 반영 PR 순서를 어길 때). 다르면 이 스택의 plan · apply 를 멈춘다.
# 값은 ignore_changes 라 리소스가 아니라 데이터 소스로 지금 값을 읽는다. writer 리소스 자체에 바뀔 것(설명 · 태그 등)이 있으면
# 읽기가 apply 로 미뤄져, 같은 apply 의 다른 변경이 먼저 적용된 뒤에 멈출 수 있다. 그런 변경은 따로 올린다
data "aws_ssm_parameter" "writer" {
  name = aws_ssm_parameter.writer.name

  depends_on = [aws_ssm_parameter.writer] # 처음 만들 때는 apply 단계에서 읽는다(plan 때는 아직 없다)
}

resource "terraform_data" "primary_matches_writer" {
  input = var.primary

  lifecycle {
    precondition {
      condition     = var.primary == data.aws_ssm_parameter.writer.insecure_value
      error_message = "primary 가 런북이 쓴 쓰기 대상(SSM ${aws_ssm_parameter.writer.name})과 다르다. 전환 · 되돌리기 뒤에는 primary 를 그 값으로 맞춘다(switching-* 이면 런북이 도는 중이거나 끊겼다. 그 스크립트의 recover 를 먼저 돌린다)."
    }
  }
}
