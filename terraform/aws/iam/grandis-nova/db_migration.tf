# RDS 이전(NCP → RDS) 동안만 쓰는 역할과 권한. 이전이 끝나면 db_migration = false 로 걷어낸다.
#
#   ProxySQL 실행 역할 nova-prod-proxysql-execution (ecs 스택 proxysql.tf)
#     ECS 에이전트가 설정 컨테이너에 넣는다: 앱 DB 계정(db/app/*), ProxySQL 관리자 · 감시 계정, 현재 쓰기 대상(SSM)
#   bastion 런북 권한 (scripts/db-migration 을 SSM Run Command 로 돌린다)
#     DB 계정 비밀 읽기, 쓰기 대상 · 덤프 위치 SSM 쓰기, ProxySQL 태스크 IP · NLB 대상 조회
#
# 시크릿은 이름 규칙으로 준다(ARN 끝 6자리는 Secrets Manager 가 붙인다). RDS 가 관리하는 마스터 비밀은 rds!db-<ID> 이름이다.
# ecs · rds 스택 리소스는 이름으로 ARN 을 만든다(이 스택이 그보다 먼저 적용된다).
locals {
  _secret_prefix = "arn:${local.partition}:secretsmanager:${var.aws_region}:${local.account_id}:secret:"

  db_migration_param_prefix = "arn:${local.partition}:ssm:${var.aws_region}:${local.account_id}:parameter/${local.name_prefix}/db-migration"
  db_migration_writer_arn   = "${local.db_migration_param_prefix}/writer"
  db_migration_coords_arn   = "${local.db_migration_param_prefix}/dump-coords"
}

# ── ProxySQL 실행 역할 ───────────────────────────────────────
# 공용 실행 역할(execution.tf)은 db/proxysql-* 를 읽지 못하고, ProxySQL 은 서비스가 아니라 따로 둔다.
# 태스크 역할은 두지 않는다 — ProxySQL 은 AWS API 를 부르지 않는다
resource "aws_iam_role" "proxysql_execution" {
  count = var.db_migration ? 1 : 0

  name               = "${local.name_prefix}-proxysql-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy_attachment" "proxysql_execution_managed" {
  count = var.db_migration ? 1 : 0

  role       = aws_iam_role.proxysql_execution[0].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "proxysql_execution" {
  count = var.db_migration ? 1 : 0

  name = "read-proxysql-config"
  role = aws_iam_role.proxysql_execution[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DbAccounts"
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue"]
        # ProxySQL 은 앱이 쓴 계정 그대로 뒷단 DB 에 붙으므로 앱 계정 비밀번호가 모두 필요하다
        Resource = [
          "${local._secret_prefix}${local.name_prefix}/db/app/*",
          "${local._secret_prefix}${local.name_prefix}/db/proxysql-admin-??????",
          "${local._secret_prefix}${local.name_prefix}/db/proxysql-monitor-??????",
        ]
      },
      {
        Sid      = "WriterParameter"
        Effect   = "Allow"
        Action   = ["ssm:GetParameters"]
        Resource = [local.db_migration_writer_arn]
      },
    ]
  })
}

# ── bastion 런북 권한 ────────────────────────────────────────
data "aws_iam_policy_document" "bastion_db_migration" {
  statement {
    sid     = "DbSecrets"
    actions = ["secretsmanager:GetSecretValue"]
    resources = concat(
      [for n in ["admin", "migrator", "exporter", "replication", "dump", "rehearsal", "proxysql-admin", "proxysql-monitor"] : "${local._secret_prefix}${local.name_prefix}/db/${n}-??????"],
      [
        "${local._secret_prefix}${local.name_prefix}/db/app/*", # 20-rds-accounts 가 NCP 와 같은 비밀번호로 RDS 계정을 만든다
      ],
    )
  }

  # RDS 마스터(nova_master) 비밀. 이름(rds!db-<리소스 ID>)은 RDS 를 만들어야 정해지므로, RDS 가 비밀에 붙이는 태그로 이 인스턴스의 것만 준다.
  # rds apply 뒤 `aws secretsmanager describe-secret` 로 태그를 확인한다. 태그가 다르면 런북이 마스터 비밀을 읽지 못하고 멈춘다(20 · 40)
  statement {
    sid       = "RdsMasterSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["${local._secret_prefix}rds!db-*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/aws:rds:primaryDBInstanceArn"
      values   = ["arn:${local.partition}:rds:${var.aws_region}:${local.account_id}:db:${local.name_prefix}-mysql"]
    }
  }

  statement {
    sid       = "ReadParameters"
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = ["${local.db_migration_param_prefix}/*"]
  }

  statement {
    sid       = "WriteRunbookParameters"
    actions   = ["ssm:PutParameter"]
    resources = [local.db_migration_writer_arn, local.db_migration_coords_arn]
  }

  # ProxySQL 노드(태스크 IP)를 찾고 NLB 대상과 대조한다. 두 조회 API 는 리소스 단위 제한을 받지 않거나 클러스터 조건만 받는다
  statement {
    sid       = "ListProxysqlTasks"
    actions   = ["ecs:ListTasks"]
    resources = ["*"]

    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [local.cluster_arn]
    }
  }

  statement {
    sid       = "DescribeProxysqlTasks"
    actions   = ["ecs:DescribeTasks"]
    resources = ["arn:${local.partition}:ecs:${var.aws_region}:${local.account_id}:task/${local.name_prefix}/*"]
  }

  statement {
    sid       = "DescribeNlbTargets"
    actions   = ["elasticloadbalancing:DescribeTargetHealth"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "bastion_db_migration" {
  count = var.db_migration ? 1 : 0

  name   = "db-migration-runbook"
  role   = aws_iam_role.bastion.id
  policy = data.aws_iam_policy_document.bastion_db_migration.json
}
