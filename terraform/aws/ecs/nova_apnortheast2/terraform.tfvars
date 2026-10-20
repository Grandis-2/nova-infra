# RDS 이전 단계 — 단계마다 이 값을 바꾸는 PR 을 올린다 (proxysql.tf 머리말)
#   1. rds 스택 apply 뒤          db_state = "rds"         (출력이 NCP 와 같아 아무것도 다시 배포되지 않는다)
#   2. ProxySQL 만들기 · 점검     proxysql_enabled = true  (앱은 아직 NCP 직결)
#   3. 앱을 ProxySQL 로           db_via_proxysql = true   (DB 를 쓰는 서비스가 모두 다시 배포된다)
#   4. 전환 뒤 앱을 RDS 직결로    db_via_proxysql = false  (rds 스택 primary = "rds" 를 먼저 apply)
#   5. ProxySQL 지우기            proxysql_enabled = false
db_state         = "rds"
proxysql_enabled = false
db_via_proxysql  = false
