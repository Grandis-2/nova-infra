# RDS 이전 기간 (scripts/db-migration). 끝나면 이 파일을 지워 평소 값(t4g.nano, MariaDB 클라이언트만)으로 되돌린다
instance_type      = "t4g.small"
root_volume_size   = 20
db_migration_tools = true

# rds 스택을 apply 하고 런북 스크립트(scripts/db-migration)가 main 에 들어간 뒤 true 로 바꾼다.
# 그 전에 켜면 rds 원격 상태가 없어 plan 이 실패한다
db_migration_runbook = false
