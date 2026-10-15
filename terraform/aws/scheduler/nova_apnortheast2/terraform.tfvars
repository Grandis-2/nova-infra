# 배치 작업 스케줄 (현재 없음)
#
# batch 앱은 @Scheduled 로 도는 상시 서비스다 (ecs 스택, singleton).
# 여기서 RunTask 로 띄우면 끝나지 않는 태스크가 스케줄마다 쌓인다.
# 실행 후 종료하는 단발 작업만 넣는다. 예:
#   "reconciliation" = {
#     description = "예약·주문·외부 등록 간 정합성 검사"
#     schedule    = "cron(0 3 * * ? *)"
#     command     = ["--spring.batch.job.name=reconciliation"]
#   }
jobs = {}
