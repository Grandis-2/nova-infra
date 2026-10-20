# RDS 이전 단계 — 단계마다 이 값을 바꾸는 PR 을 올린다 (scripts/db-migration/README.md)
#   1. 계정 만들기 · 덤프 적재        read_only = false, local_infile = true, primary = "ncp"
#   2. 복제 시작 전                    read_only = true,  local_infile = false
#   3. 전환 30분 전                    read_only = false
#   4. 전환 뒤 반영 PR                 primary = "rds", replication_filter = false
#      되돌린 뒤(70-rollback)           primary = "ncp"
#   primary 는 런북이 쓴 쓰기 대상(SSM writer)과 같아야 plan 이 통과한다(db_migration.tf)
read_only          = false
local_infile       = true
primary            = "ncp"
replication_filter = true
