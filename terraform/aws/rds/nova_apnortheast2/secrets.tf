# DB 계정 비밀. NCP 시절 ncp-database 스택이 만들었고, NCP 해체 전에 이 스택으로 소유권을 옮겼다(import).
# 앱 · Flyway · exporter 는 username · password 만 읽는다. 값(비밀 버전)은 이 스택이 쓰지 않는다 — 비밀번호를 바꾸려면
# RDS 계정과 함께 바꾸는 별도 작업으로 한다(값의 host 는 NCP 시절 그대로 남아 있고 쓰지 않는다).
locals {
  # 서비스 키 → 비밀 ARN (가져올 때의 대상. 이름 끝 6자리는 Secrets Manager 가 붙인 것)
  imported_app_secrets = {
    batch    = "arn:aws:secretsmanager:ap-northeast-2:316708313927:secret:nova-prod/db/app/batch-OLmBPs"
    catalog  = "arn:aws:secretsmanager:ap-northeast-2:316708313927:secret:nova-prod/db/app/catalog-e625i8"
    member   = "arn:aws:secretsmanager:ap-northeast-2:316708313927:secret:nova-prod/db/app/member-aL3tus"
    mock     = "arn:aws:secretsmanager:ap-northeast-2:316708313927:secret:nova-prod/db/app/mock-ZeLlIa"
    order    = "arn:aws:secretsmanager:ap-northeast-2:316708313927:secret:nova-prod/db/app/order-RzQJWR"
    payment  = "arn:aws:secretsmanager:ap-northeast-2:316708313927:secret:nova-prod/db/app/payment-LqSKFP"
    preorder = "arn:aws:secretsmanager:ap-northeast-2:316708313927:secret:nova-prod/db/app/preorder-bJf2Vs"
    worker   = "arn:aws:secretsmanager:ap-northeast-2:316708313927:secret:nova-prod/db/app/worker-s0kRR4"
  }
  imported_ops_secrets = {
    admin    = "arn:aws:secretsmanager:ap-northeast-2:316708313927:secret:nova-prod/db/admin-TAP4tl"
    migrator = "arn:aws:secretsmanager:ap-northeast-2:316708313927:secret:nova-prod/db/migrator-CckHVI"
  }
  imported_exporter_secret = "arn:aws:secretsmanager:ap-northeast-2:316708313927:secret:nova-prod/db/exporter-Dg81Az"
}

resource "aws_secretsmanager_secret" "app" {
  for_each = local.imported_app_secrets

  name                    = "${local.name_prefix}/db/app/${each.key}"
  description             = "DB account for the ${each.key} service (MySQL)"
  recovery_window_in_days = 7

  tags = { Service = each.key }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_secretsmanager_secret" "ops" {
  for_each = local.imported_ops_secrets

  name                    = "${local.name_prefix}/db/${each.key}"
  description             = "MySQL ${each.key} account (operators and migrations only)"
  recovery_window_in_days = 7

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_secretsmanager_secret" "exporter" {
  name                    = "${local.name_prefix}/db/exporter"
  description             = "MySQL read-only account for mysqld_exporter (observability stack only)"
  recovery_window_in_days = 7

  tags = { Service = "obs" }

  lifecycle {
    prevent_destroy = true
  }
}

import {
  for_each = local.imported_app_secrets
  to       = aws_secretsmanager_secret.app[each.key]
  id       = each.value
}

import {
  for_each = local.imported_ops_secrets
  to       = aws_secretsmanager_secret.ops[each.key]
  id       = each.value
}

import {
  to = aws_secretsmanager_secret.exporter
  id = local.imported_exporter_secret
}
