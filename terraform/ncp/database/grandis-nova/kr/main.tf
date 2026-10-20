# NCP Cloud DB for MySQL — 해체됨.
#
# 2026-10-20 운영 DB 를 AWS RDS 로 옮겼다(에픽 NV-678, 전환 09:33 UTC). 전환 뒤 데이터 대조에서 NCP 에만 있는 행은 0건이었다.
# 이 스택은 NCP 의 DB · 계정 · ACG · VPC 를 지우고, AWS 쪽에 만들었던 DB 계정 비밀은 지우지 않고 관리만 뗀다.
# 비밀(nova-prod/db/app/* · db/migrator · db/admin · db/exporter)은 rds 스택이 import 로 넘겨받았다(NV-718, secrets.tf).
#
# apply 로 NCP 리소스가 모두 지워지면 상태가 비므로, 이 디렉터리와 atlantis.yaml 의 ncp-database 프로젝트는 정리 작업에서 지운다.

removed {
  from = aws_secretsmanager_secret.service
  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_secretsmanager_secret_version.service
  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_secretsmanager_secret.ops
  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_secretsmanager_secret_version.ops
  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_secretsmanager_secret.exporter
  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_secretsmanager_secret_version.exporter
  lifecycle {
    destroy = false
  }
}

# 비밀번호 값은 Terraform 상태에만 있던 것이다. 지워도 실제 비밀 · RDS 계정에는 영향이 없다
removed {
  from = random_password.user
  lifecycle {
    destroy = false
  }
}
