# RDS 이전 기간 (scripts/db-migration). 끝나면 이 파일을 지워 평소 값(t4g.nano, MariaDB 클라이언트만)으로 되돌린다.
# micro(1GB): nano(0.5GB)는 dnf 설치 · MySQL Shell 덤프 · 런북 세션을 함께 돌리기에 메모리가 빠듯하다. 데이터가 수 MB 라 디스크는 그대로 둔다
instance_type      = "t4g.micro"
db_migration_tools = true

# 런북 단계를 SSM 문서로 둔다(db_migration.tf). rds 스택 원격 상태와 scripts/db-migration 이 있어야 한다.
# 이전이 끝나면 false 로 먼저 apply 한 뒤 scripts/db-migration 을 지운다(반대로 하면 이 스택 plan 이 실패한다)
db_migration_runbook = true
