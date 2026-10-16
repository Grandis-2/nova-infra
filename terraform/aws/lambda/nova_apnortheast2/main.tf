# ─────────────────────────────────────────────────────────────
# Lambda 함수들 (이 VPC)
#
#   코드     저장소의 functions/<이름>/  (Python, 표준 라이브러리 · boto3 만)
#   틀       ../_modules/function        코드 묶기 · 실행 역할 · 로그 그룹 · 재시도 · 실패 큐(SQS) · 경보
#   이 스택  함수마다 트리거 · API 권한 · 환경 변수 · 네트워크
#
# 함수 하나에 파일 하나(<이름>.tf). S3 이벤트 연결은 버킷마다 리소스가 하나뿐이라 s3_notifications.tf 에 모은다.
# ─────────────────────────────────────────────────────────────

locals {
  functions_root = "${path.module}/../../../../functions"
  alerts_topic   = data.aws_sns_topic.alerts.arn
  app_subnet_ids = data.terraform_remote_state.vpc.outputs.app_subnet_ids
  log_bucket     = data.terraform_remote_state.s3.outputs.log_bucket
}
