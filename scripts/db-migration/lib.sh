#!/usr/bin/env bash
# db-migration 스크립트가 함께 쓰는 함수. 직접 실행하지 않고 source 한다.
#
# 접속 정보는 환경변수로 받고, 값은 화면에 찍지 않는다.
#   NCP_HOST NCP_PORT NCP_USER NCP_PASSWORD         NCP(소스) 관리 계정 (운영: nova_admin)
#   RDS_HOST RDS_PORT RDS_USER RDS_PASSWORD         RDS(대상) 마스터 계정
#   RDS_MODE                                        rds    : 복제 제어에 mysql.rds_* 프로시저를 쓴다 (운영, 기본값)
#                                                   native : MySQL 명령을 쓴다 (로컬 시험. RDS 프로시저가 없다)
#   RDS_CONTROL_USER RDS_CONTROL_PASSWORD           native 에서 복제 제어 · read_only 를 바꾸는 계정 (로컬 root)
#   PROXYSQL_NODES PROXYSQL_USER PROXYSQL_PASSWORD  ProxySQL 관리 포트("호스트:포트 ...")와 관리 계정
#   PROXYSQL_EXPECTED_NODES                         노드 수 (기본 2). 다르면 시작하지 않는다
#   PROXYSQL_NODES_CMD                              실제 노드 목록("호스트:포트" 한 줄에 하나)을 내는 명령. 주면 PROXYSQL_NODES 와 대조한다
#   WRITER_SSM_PARAM 또는 WRITER_FILE               현재 쓰기 대상(ncp · rds)을 남길 곳
#   COORDS_FILE COORDS_SSM_PARAM                    덤프 때의 복제 시작점을 남기고 읽을 곳 (파일 기본: $WORK_DIR/dump-coords.env)
#   WORK_DIR                                        덤프 · 복사 파일을 둘 곳 (기본 /work, 운영 bastion 은 SSM 문서가 준다)
#
# SQL 은 표준 입력으로 넘긴다. -e 로 넘기면 비밀번호가 든 문장이 프로세스 목록에 보인다.
# 비밀번호가 든 변수를 다루므로 bash -x 로 돌리지 않는다(추적 출력에 찍힌다).
set -euo pipefail
export LC_ALL=C.UTF-8 # MySQL Shell 이 없는 로케일(en_US.UTF-8)을 찾으며 내는 경고를 막고, EPOCHREALTIME 의 소수점을 . 로 둔다
umask 077             # 덤프 · 복사 파일과 세션 파이프를 실행한 계정만 읽게 한다
[[ $- != *x* ]] || { echo "bash -x 로 돌리지 않는다(비밀번호가 추적 출력에 찍힌다)" >&2; exit 1; }

log() { printf '%s %s\n' "$(date -u +%H:%M:%S.%3N)" "$*" >&2; }
die() { log "중단: $*"; exit 1; }
need() { local v; for v in "$@"; do [[ -n "${!v:-}" ]] || die "환경변수 $v 가 비어 있습니다"; done; }
_now() { local t=${EPOCHREALTIME/./}; NOW=$((t / 1000)); } # 지금 시각(ms)을 NOW 에. 대기 구간의 반복에서 fork 하지 않게
ms() { _now; echo "$NOW"; }
WORK_DIR="${WORK_DIR:-/work}"

# 끝날 때 할 일. 스크립트는 ON_EXIT 에 함수 이름을 넣고, 세션 정리는 여기서 한다
ON_EXIT=""
_lib_exit() {
  local rc=$?
  trap - EXIT
  if [[ -n "$ON_EXIT" ]]; then "$ON_EXIT" "$rc" || rc=$?; fi
  sess_close_all
  [[ -z "$_LOCKED" ]] || rm -rf "$_LOCKED"
  exit "$rc"
}
trap _lib_exit EXIT

# ── 한 번 쓰고 닫는 접속 ────────────────────────────────────
# 비밀번호는 명령 인자 · 환경변수 대신 파일 디스크립터로 넘긴다(프로세스 목록에 남지 않게). 옵션 파일에서 # 은 주석이 되므로
# 큰따옴표로 감싸고, 큰따옴표 안에서 이스케이프가 되는 " \ 와 줄바꿈은 받지 않는다(NCP 비밀번호 규칙도 쓰지 않는다).
pw_ok() { [[ "$2" != *[\"\\$'\n']* ]] || die "$1 비밀번호에 쓸 수 없는 문자(\" \\ 줄바꿈)가 있다"; }
_mysql_cmd() { # _mysql_cmd <제한 초 | exec> <host> <port> <user> <password> <ssl-mode> [mysql 옵션...]
  local limit=$1 host=$2 port=$3 user=$4 pass=$5 ssl=$6
  shift 6
  local run=(timeout "$limit")
  [[ "$limit" != exec ]] || run=(exec) # 세션: 백그라운드 서브셸을 mysql 로 바꿔 kill 이 mysql 에 닿게 한다
  "${run[@]}" mysql --defaults-extra-file=<(printf '[client]\nuser="%s"\npassword="%s"\n' "$user" "$pass") \
    --host="$host" --port="$port" --ssl-mode="$ssl" --default-character-set=utf8mb4 \
    --connect-timeout=5 --batch --skip-column-names "$@"
}
# 한 번 쓰는 호출은 MYSQL_CALL_TIMEOUT(기본 30초)을 넘으면 끊는다. 응답 없는 호출 하나가 스크립트를 멈추지 않게
_mysql() { # _mysql <host> <port> <user> <password> <ssl-mode> [mysql 옵션...]  (SQL 은 표준 입력)
  pw_ok "$3" "$4"
  _mysql_cmd "${MYSQL_CALL_TIMEOUT:-30}" "$@"
}

# shellcheck disable=SC2120 # mysql 옵션은 필요할 때만 넘긴다
ncp() { _mysql "$NCP_HOST" "$NCP_PORT" "$NCP_USER" "$NCP_PASSWORD" REQUIRED "$@"; }
rds() { _mysql "$RDS_HOST" "$RDS_PORT" "$RDS_USER" "$RDS_PASSWORD" REQUIRED "$@"; }
ncp_val() { ncp <<<"$1"; }
rds_val() { rds <<<"$1"; }

# 복제 제어 · read_only. 운영(rds)은 마스터 계정으로 mysql.rds_* 를 부르고 read_only 는 파라미터 그룹(Terraform)이 바꾼다.
# 로컬(native)은 RDS 프로시저가 없어 제어 계정으로 MySQL 명령을 직접 쓴다.
rds_ctl_args() {
  if [[ "${RDS_MODE:-rds}" == native ]]; then
    echo "$RDS_HOST $RDS_PORT $RDS_CONTROL_USER"
  else
    echo "$RDS_HOST $RDS_PORT $RDS_USER"
  fi
}
rds_ctl_password() { if [[ "${RDS_MODE:-rds}" == native ]]; then echo "$RDS_CONTROL_PASSWORD"; else echo "$RDS_PASSWORD"; fi; }
rds_ctl() {
  local host port user
  read -r host port user <<<"$(rds_ctl_args)"
  _mysql "$host" "$port" "$user" "$(rds_ctl_password)" REQUIRED "$@"
}
repl_stop_sql() { if [[ "${RDS_MODE:-rds}" == native ]]; then echo "STOP REPLICA"; else echo "CALL mysql.rds_stop_replication"; fi; }
repl_start_sql() { if [[ "${RDS_MODE:-rds}" == native ]]; then echo "START REPLICA"; else echo "CALL mysql.rds_start_replication"; fi; }

# ProxySQL 관리 포트. VPC 안(bastion)에서만 열리고 TLS 를 쓰지 않는다
proxysql() { # proxysql <호스트:포트> [mysql 옵션...]
  local node=$1
  shift
  _mysql "${node%:*}" "${node##*:}" "$PROXYSQL_USER" "$PROXYSQL_PASSWORD" DISABLED "$@"
}

# ── 열어 둔 채 다시 쓰는 접속 (세션) ───────────────────────
# 전환처럼 시간이 중요한 구간은 호출마다 프로세스 · TLS 연결을 새로 만들면 그것만으로 수십 ms 가 든다.
# 세션은 mysql 클라이언트 하나를 파이프에 붙여 두고 문장마다 표식 줄을 함께 보내 결과의 끝을 안다.
#   sess_open <이름> <host> <port> <user> <password> <ssl-mode>   여는 데 실패하면 1
#   sess_q <이름> <제한 ms> <SQL>   결과는 SQ(줄바꿈으로 이은 행). 0 성공 · 1 SQL 오류 · 2 시간 초과나 연결 끊김
# 시간 초과 · 끊김이면 그 세션을 닫는다(늦게 온 결과가 다음 문장의 결과로 읽히지 않게). 다음 조회가 다시 연다.
# 보내기(_sess_send)와 받기(_sess_recv)를 나눠 두어, 여러 노드에 먼저 다 보낸 뒤 한 마감 시각 안에서 결과를 모은다.
declare -A _S_ARGS=() _S_PASS=() _S_PID=() _S_W=() _S_R=() _S_MARK=()
_S_DIR=""
_S_SEQ=0
SQ=""

# 접속 정보만 등록한다. 첫 조회 때 붙는다(닿지 않는 DB 가 있어도 다른 일을 먼저 할 수 있게)
sess_define() { # sess_define <이름> <host> <port> <user> <password> <ssl-mode>
  pw_ok "$4" "$5"
  _S_ARGS[$1]="$2 $3 $4 $6"
  _S_PASS[$1]=$5
}

sess_open() {
  local name=$1
  sess_define "$@"
  _sess_spawn "$name"
  if ! _sess_run "$name" 6000 "SELECT 1" || [[ "$SQ" != 1 ]]; then
    SQ="$name 접속 실패: $SQ"
    _sess_kill "$name"
    return 1
  fi
}

# mysql 클라이언트를 띄우고 파이프를 연다. 접속은 첫 문장과 함께 확인한다(접속에 실패하면 클라이언트가 ERROR 줄을 내고 끝난다)
_sess_spawn() {
  local name=$1 host port user ssl in out w r
  read -r host port user ssl <<<"${_S_ARGS[$name]}"
  [[ -n "$_S_DIR" ]] || _S_DIR=$(mktemp -d)
  in="$_S_DIR/$name.in"
  out="$_S_DIR/$name.out"
  rm -f "$in" "$out"
  mkfifo "$in" "$out"
  _mysql_cmd exec "$host" "$port" "$user" "${_S_PASS[$name]}" "$ssl" --unbuffered --force --skip-reconnect <"$in" >"$out" 2>&1 &
  _S_PID[$name]=$!
  exec {w}>"$in" {r}<"$out"
  _S_W[$name]=$w
  _S_R[$name]=$r
}

_sess_kill() {
  local name=$1 w r
  [[ -n "${_S_PID[$name]:-}" ]] || return 0
  w=${_S_W[$name]}
  r=${_S_R[$name]}
  kill "${_S_PID[$name]}" 2>/dev/null || true
  { exec {w}>&- {r}<&-; } 2>/dev/null || true # 묶음 밖에 2> 를 두면 exec 가 셸의 stderr 를 영구히 바꾼다
  wait "${_S_PID[$name]}" 2>/dev/null || true
  unset "_S_PID[$name]" "_S_W[$name]" "_S_R[$name]" "_S_MARK[$name]"
}

sess_close_all() {
  local name
  for name in "${!_S_PID[@]}"; do _sess_kill "$name"; done
  [[ -z "$_S_DIR" ]] || rm -rf "$_S_DIR"
}

# 문장 하나를 보낸다. 닫힌 세션이면 먼저 다시 띄운다. 쓰기에 실패하면 세션을 닫고 1
_sess_send() { # _sess_send <이름> <SQL>
  local name=$1 rc=0
  [[ -n "${_S_PID[$name]:-}" ]] || _sess_spawn "$name"
  _S_SEQ=$((_S_SEQ + 1))
  _S_MARK[$name]="#END-$_S_SEQ#"
  # 끊긴 파이프에 쓸 때 셸이 SIGPIPE 로 죽지 않게 이 쓰기 동안만 무시한다(전역으로 무시하면 자식 프로세스에 물려진다)
  trap '' PIPE
  printf '%s;\nSELECT '\''%s'\'';\n' "$2" "${_S_MARK[$name]}" 1>&"${_S_W[$name]}" 2>/dev/null || rc=$?
  trap - PIPE
  if ((rc != 0)); then
    _sess_kill "$name"
    return 1
  fi
}

# 보낸 문장의 결과를 마감 시각(ms)까지 읽는다. 결과는 SQ. 0 성공 · 1 SQL 오류 · 2 시간 초과나 끊김(세션을 닫는다)
_sess_recv() { # _sess_recv <이름> <마감 시각 ms>
  local name=$1 end=$2 line rem tmo out="" err=""
  if [[ -z "${_S_MARK[$name]:-}" ]]; then
    SQ="연결 끊김"
    return 2
  fi
  while :; do
    _now
    rem=$((end - NOW))
    if ((rem <= 0)); then
      _sess_kill "$name"
      SQ="시간 초과${err:+: $err}"
      return 2
    fi
    printf -v tmo '%d.%03d' $((rem / 1000)) $((rem % 1000))
    if ! IFS= read -r -t "$tmo" -u "${_S_R[$name]}" line; then
      _sess_kill "$name"
      SQ="응답 없음 또는 연결 끊김${err:+: $err}${out:+ ($out)}"
      return 2
    fi
    [[ "$line" != "${_S_MARK[$name]}" ]] || break
    if [[ "$line" == ERROR\ * ]]; then err+="$line"; else out+="$line"$'\n'; fi
  done
  unset "_S_MARK[$name]"
  if [[ -n "$err" ]]; then
    SQ=$err
    return 1
  fi
  SQ=${out%$'\n'}
}

_sess_run() { # _sess_run <이름> <제한 ms> <SQL>
  _sess_send "$1" "$3" || { SQ="연결 끊김"; return 2; }
  _now
  _sess_recv "$1" $((NOW + $2))
}

sess_q() { _sess_run "$@"; }

# 꼭 성공해야 하는 조회. 실패하면 멈춘다(아무것도 바꾸기 전의 확인에 쓴다)
sess_must() { # sess_must <이름> <SQL>
  sess_q "$1" "${SESSION_QUERY_TIMEOUT_MS:-5000}" "$2" || die "$1: $SQ"
}

ncp_open() { sess_open ncp "$NCP_HOST" "$NCP_PORT" "$NCP_USER" "$NCP_PASSWORD" REQUIRED || die "$SQ"; }
rds_open() { sess_open rds "$RDS_HOST" "$RDS_PORT" "$RDS_USER" "$RDS_PASSWORD" REQUIRED || die "$SQ"; }
rds_ctl_open() {
  local host port user
  read -r host port user <<<"$(rds_ctl_args)"
  sess_open rds_ctl "$host" "$port" "$user" "$(rds_ctl_password)" REQUIRED || die "$SQ"
}

# ── ProxySQL 노드 ───────────────────────────────────────────
# 서버는 같은 호스트그룹(PROXYSQL_HOSTGROUP, 기본 10)에 둘 다 두고 상태만 바꾼다.
#   ONLINE        쓰기 대상
#   OFFLINE_SOFT  이 서버로 새 연결을 만들지 않는다. 뒷단 연결을 쥔 세션은 놓을 때까지 이 서버로 보낸다. 보낼 서버가 없으면
#                 새 쿼리는 오류 대신 mysql-connect_timeout_server_max 까지 ProxySQL 안에서 기다린다
#   OFFLINE_HARD  그룹에서 뺀다(런타임 표에서 사라진다)
# 함수는 모든 노드에 먼저 다 보낸 뒤 한 마감 시각 안에서 결과를 모은다. 그래서 한 노드가 멈춰도 다른 노드는 늦어지지 않는다.
# 한 노드라도 답하지 않거나 값이 이상하면 실패를 돌려준다(0 이나 빈 값으로 보지 않는다).
PX=()        # 노드별 세션 이름
PX_NODE=()   # 노드별 "호스트:포트"
PX_OUT=()    # px_all_q 결과: 노드별 출력
PX_RC=()     # px_all_q 결과: 노드별 0 · 1 · 2 (sess_q 와 같다)
PX_STATE=()  # px_state 결과: 노드별 ONLINE · OFFLINE_SOFT · OFFLINE_HARD · SHUNNED · ?(조회 실패)
PX_FAILED="" # px_set 이 실패한 노드
PX_USED=0    # px_used 결과
PX_HG="${PROXYSQL_HOSTGROUP:-10}"
px_hg() { echo "$PX_HG"; }
[[ "$PX_HG" =~ ^[0-9]+$ ]] || { echo "PROXYSQL_HOSTGROUP 은 숫자다" >&2; exit 1; }

px_open() {
  local i=0 node
  PX=()
  PX_NODE=()
  for node in $PROXYSQL_NODES; do
    sess_open "px$i" "${node%:*}" "${node##*:}" "$PROXYSQL_USER" "$PROXYSQL_PASSWORD" DISABLED || die "ProxySQL $node: $SQ"
    PX+=("px$i")
    PX_NODE+=("$node")
    i=$((i + 1))
  done
  ((${#PX[@]} == ${PROXYSQL_EXPECTED_NODES:-2})) || die "ProxySQL 노드가 ${#PX[@]} 개다. ${PROXYSQL_EXPECTED_NODES:-2} 개여야 한다"
  px_nodes_check || die "노드 목록이 실제와 다르다. $SQ"
}

# PROXYSQL_NODES_CMD(실제 노드 목록)가 있으면 받은 목록과 같은지 본다. 태스크가 바뀌었으면 1 (SQ 에 차이)
px_nodes_check() {
  local want have
  [[ -n "${PROXYSQL_NODES_CMD:-}" ]] || return 0
  # 명령 안의 조회 하나가 실패해도 나머지 결과만으로 "같다"가 나오지 않게 pipefail 로 돌린다
  want=$(bash -o pipefail -c "$PROXYSQL_NODES_CMD" | sort | tr '\n' ' ') || { SQ="PROXYSQL_NODES_CMD 실패"; return 1; }
  have=$(tr ' ' '\n' <<<"$PROXYSQL_NODES" | grep . | sort | tr '\n' ' ')
  [[ "$want" == "$have" ]] || { SQ="실제: $want / 받은 값: $have"; return 1; }
}

px_all_q() { # px_all_q <제한 ms> <SQL>   모든 노드에 보내고 마감 시각까지 모은다. 한 노드라도 실패하면 1
  local limit=$1 sql=$2 i end rc=0
  _now
  end=$((NOW + limit))
  PX_OUT=()
  PX_RC=()
  # 살아 있는 세션에 먼저 보내고, 닫힌 세션은 그 뒤에 다시 띄운다(다시 띄우는 시간이 살아 있는 노드를 늦추지 않게)
  for i in "${!PX[@]}"; do [[ -z "${_S_PID[${PX[$i]}]:-}" ]] || _sess_send "${PX[$i]}" "$sql" || true; done
  for i in "${!PX[@]}"; do [[ -n "${_S_PID[${PX[$i]}]:-}" ]] || _sess_send "${PX[$i]}" "$sql" || true; done
  for i in "${!PX[@]}"; do
    if _sess_recv "${PX[$i]}" "$end"; then PX_RC[i]=0; else PX_RC[i]=$?; rc=1; fi
    PX_OUT[i]=$SQ
  done
  return $rc
}

px_state() { # px_state <호스트> [제한 ms]   PX_STATE 를 채운다. 조회에 실패한 노드가 있으면 1
  local i rc=0
  px_all_q "${2:-1000}" "SELECT COALESCE(MAX(status), 'OFFLINE_HARD') FROM runtime_mysql_servers WHERE hostgroup_id=$PX_HG AND hostname='$1'" || true
  PX_STATE=()
  for i in "${!PX[@]}"; do
    if [[ ${PX_RC[i]} == 0 && "${PX_OUT[i]}" =~ ^(ONLINE|OFFLINE_SOFT|OFFLINE_HARD|SHUNNED)$ ]]; then
      PX_STATE+=("${PX_OUT[i]}")
    else
      PX_STATE+=("?")
      rc=1
    fi
  done
  return $rc
}
px_state_text() { local i s=""; for i in "${!PX[@]}"; do s+="${PX_NODE[$i]}=${PX_STATE[$i]:-?} "; done; echo "${s% }"; }
px_all() { # px_all <상태>   방금 읽은 PX_STATE 가 모든 노드에서 그 상태인지
  local s
  for s in "${PX_STATE[@]}"; do [[ "$s" == "$1" ]] || return 1; done
}
px_any() { local s; for s in "${PX_STATE[@]}"; do [[ "$s" != "$1" ]] || return 0; done; return 1; }

px_set() { # px_set <제한 ms> "<호스트>=<상태> ..."   노드마다 한 번에 싣는다. 실패한 노드는 PX_FAILED, 하나라도 있으면 1
  local limit=$1 pairs=$2 sql="" pair i
  for pair in $pairs; do
    sql+="UPDATE mysql_servers SET status='${pair#*=}' WHERE hostgroup_id=$PX_HG AND hostname='${pair%%=*}';"$'\n'
  done
  sql+="LOAD MYSQL SERVERS TO RUNTIME"
  PX_FAILED=""
  px_all_q "$limit" "$sql" && return 0
  for i in "${!PX[@]}"; do ((PX_RC[i] == 0)) || PX_FAILED+="${PX_NODE[$i]}(${PX_OUT[i]}) "; done
  return 1
}

px_save() { # 런타임 상태를 디스크에도 남긴다(태스크 안에서 ProxySQL 만 다시 뜰 때를 대비). 대기 구간 밖에서 부른다
  local i
  px_all_q 3000 "SAVE MYSQL SERVERS TO DISK" && return 0
  for i in "${!PX[@]}"; do ((PX_RC[i] == 0)) || log "경고: ${PX_NODE[$i]} 디스크 저장 실패 (${PX_OUT[i]})"; done
}

px_used() { # px_used <호스트> [제한 ms]   모든 노드에서 그 서버에 묶인 뒷단 연결 수의 합을 PX_USED 에. 실패하면 1
  local i total=0
  px_all_q "${2:-1000}" "SELECT COALESCE(SUM(ConnUsed), 0) FROM stats_mysql_connection_pool WHERE hostgroup=$PX_HG AND srv_host='$1'" || return 1
  for i in "${!PX[@]}"; do
    [[ "${PX_OUT[i]}" =~ ^[0-9]+$ ]] || return 1
    total=$((total + PX_OUT[i]))
  done
  PX_USED=$total
}

px_holders() { # px_holders <호스트>   그 서버의 뒷단 연결을 쥔 세션 (고정 세션 · 긴 트랜잭션을 찾을 때)
  local i
  px_all_q 3000 "SELECT CONCAT(user, ' ', cli_host, ' ', command, ' ', time_ms, 'ms ', COALESCE(SUBSTR(info, 1, 80), '')) FROM stats_mysql_processlist WHERE hostgroup=$PX_HG AND srv_host='$1'" || true
  for i in "${!PX[@]}"; do
    if ((PX_RC[i] != 0)); then
      log "  ${PX_NODE[$i]} 조회 실패 (${PX_OUT[i]})"
    elif [[ -n "${PX_OUT[i]}" ]]; then
      sed "s/^/  ${PX_NODE[$i]} /" <<<"${PX_OUT[i]}" >&2
    fi
  done
}

# 사전 확인: 두 서버가 모든 노드의 설정 표에 정확히 한 행씩 있고, 전환에 필요한 설정이 런타임에 들어가 있다
px_preflight() { # px_preflight <옮길 서버> <받을 서버>
  local from=$1 to=$2 i host n v
  for i in "${!PX[@]}"; do
    for host in "$from" "$to"; do
      sess_q "${PX[$i]}" 3000 "SELECT COUNT(*) FROM mysql_servers WHERE hostgroup_id=$PX_HG AND hostname='$host'" || die "${PX_NODE[$i]}: $SQ"
      [[ "$SQ" == 1 ]] || die "${PX_NODE[$i]} 의 호스트그룹 $PX_HG 에 $host 가 ${SQ}행 있다. 정확히 1행이어야 한다(이름 확인)"
    done
    sess_q "${PX[$i]}" 3000 "SELECT variable_value FROM runtime_global_variables WHERE variable_name='mysql-auto_increment_delay_multiplex'" || die "${PX_NODE[$i]}: $SQ"
    [[ "$SQ" == 0 ]] || die "${PX_NODE[$i]} mysql-auto_increment_delay_multiplex=$SQ (0 이어야 비울 수 있다)"
    sess_q "${PX[$i]}" 3000 "SELECT variable_value FROM runtime_global_variables WHERE variable_name='mysql-connect_timeout_server_max'" || die "${PX_NODE[$i]}: $SQ"
    v=$SQ
    [[ "$v" =~ ^[0-9]+$ ]] && ((v >= 10000)) || die "${PX_NODE[$i]} mysql-connect_timeout_server_max=$v (10000 이상이어야 대기 중 쿼리가 실패하지 않는다)"
    for n in auto_increment_increment transaction_read_only character_set_database; do
      sess_q "${PX[$i]}" 3000 "SELECT COUNT(*) FROM runtime_mysql_query_rules WHERE active=1 AND multiplex=2 AND match_digest LIKE '%$n%'" || die "${PX_NODE[$i]}: $SQ"
      [[ "$SQ" -ge 1 ]] || die "${PX_NODE[$i]} 에 $n 조회의 multiplex=2 쿼리 규칙이 없다(없으면 연결이 고정돼 비울 수 없다)"
    done
  done
}

# ProxySQL 노드에서 그 서버로 실제로 붙는지 본다. 설정에는 두 서버를 늘 넣어 둔 감시 전용 그룹(PROXYSQL_CHECK_HOSTGROUP,
# 기본 쓰기 그룹 + 1, 이 그룹을 쓰는 계정 · 규칙은 없다)이 있어 ProxySQL 감시 기능이 계속 접속 · ping 해 본다. 그 기록에서
# 마지막 접속과 ping 이 최근 MONITOR_MAX_AGE_SECONDS(기본 120) 안에 오류 없이 성공했는지 본다(네트워크 · TLS · 감시 계정).
# 감시 그룹의 상태는 보지 않는다. 한 번 SHUNNED 가 되면 트래픽이 없는 그룹이라 스스로 풀리지 않기 때문이다(ProxySQL 은 연결을
# 요청할 때만 SHUNNED 를 푼다). 서버를 막 넣어 기록이 없으면 MONITOR_WAIT_SECONDS(기본 75)까지 기다린다
px_reachable() { # px_reachable <서버>
  local host=$1 i age=$((${MONITOR_MAX_AGE_SECONDS:-120} * 1000000)) chk="${PROXYSQL_CHECK_HOSTGROUP:-$((PX_HG + 1))}" t end why
  _now
  end=$((NOW + ${MONITOR_WAIT_SECONDS:-75} * 1000))
  for i in "${!PX[@]}"; do
    sess_must "${PX[$i]}" "SELECT COUNT(*) FROM mysql_servers WHERE hostgroup_id=$chk AND hostname='$host'"
    [[ "$SQ" == 1 ]] || die "${PX_NODE[$i]} 의 감시 그룹 $chk 에 $host 가 없다(ProxySQL 설정 확인)"
    while :; do
      why=""
      for t in connect ping; do
        sess_must "${PX[$i]}" "SELECT CONCAT(CAST(strftime('%s', 'now') AS INTEGER) * 1000000 - time_start_us < $age, ',', COALESCE(NULLIF(${t}_error, ''), 'ok')) FROM monitor.mysql_server_${t}_log WHERE hostname='$host' ORDER BY time_start_us DESC LIMIT 1"
        [[ "$SQ" == "1,ok" ]] || why="$t ${SQ:-기록 없음}"
      done
      [[ -n "$why" ]] || break
      _now
      ((NOW < end)) || die "${PX_NODE[$i]} 에서 $host 로의 최근 감시가 성공이 아니다($why). ProxySQL 에서 그 서버에 닿지 않는다"
      sleep 2
    done
  done
}

# 조용한 순간: 옮길 서버에 묶인 뒷단 연결이 0 인 때. 대기를 이때 시작하면 비우기를 기다릴 일이 거의 없다.
# QUIET_WAIT_MS(기본 10초) 안에 한 번도 0 이 아니면 고정된 세션이나 긴 트랜잭션이 있는 것이라, 쥔 세션을 보여 주고 멈춘다.
px_wait_quiet() { # px_wait_quiet <서버>
  local host=$1 end
  _now
  end=$((NOW + ${QUIET_WAIT_MS:-10000}))
  while _now && ((NOW < end)); do
    if px_used "$host" 1000 && ((PX_USED == 0)); then return 0; fi
  done
  log "$host 에 묶인 연결이 ${QUIET_WAIT_MS:-10000} ms 동안 0 이 되지 않았다. 쥔 세션:"
  px_holders "$host"
  die "조용한 순간이 없다. 고정 세션(쿼리 규칙 확인)이나 긴 트랜잭션을 정리한 뒤 다시 한다(아무것도 바꾸지 않았다)"
}

# 실제 상태를 읽어 모든 노드를 한쪽으로 맞춘다(끝날 때의 정리 · recover). SETTLED 에 forward · back 을 남긴다.
#   hint=back : 받을 서버를 넣으라는 명령을 보낸 적이 없다. 닿는 노드부터 바로 되돌린다
#   hint=forward : 이미 앞으로 맞춘 것을 다시 싣는다(recover 가 늦게 남은 변경을 덮을 때)
#   hint=auto : 받을 서버가 한 노드에서라도 빠져 있지 않으면(ONLINE · SHUNNED 등) 앞으로(모두 받을 서버로), 모든 노드에서 빠져
#               있으면 뒤로 간다. SHUNNED 는 넣은 뒤 연결 오류로 잠깐 쉬는 상태라 이미 쓰기를 받았을 수 있다.
#               한 노드라도 읽지 못하면 판단하지 않고 다시 읽는다(그 노드만 받을 서버로 넘어갔을 수 있다)
# 방향은 한 번 정하면 바꾸지 않는다. 두 서버를 함께 싣는다(한 그룹에 두 서버가 들어간 채 남지 않게).
# 맞춘 쪽 서버가 SHUNNED(연결 오류로 잠깐 쉬는 상태)여도 맞춘 것으로 본다. ProxySQL 이 스스로 다시 붙는다.
# 닿지 않는 노드가 있으면 SETTLE_TIMEOUT_MS(기본 20초)까지 되풀이하고, 그래도 안 되면 1. SETTLE_FIRST_MS 는 처음 실은 시각
SETTLED=""
SETTLE_FIRST_MS=0
px_settle() { # px_settle <옮길 서버> <받을 서버> <back|forward|auto>
  local from=$1 to=$2 hint=$3 end
  _now
  end=$((NOW + ${SETTLE_TIMEOUT_MS:-20000}))
  SETTLED=""
  SETTLE_FIRST_MS=0
  [[ "$hint" == auto ]] || SETTLED=$hint
  while :; do
    if [[ -z "$SETTLED" ]] && px_state "$to" 1000; then
      if px_all OFFLINE_HARD; then SETTLED=back; else SETTLED=forward; fi
    fi
    case $SETTLED in
      forward) px_set 1000 "$to=ONLINE $from=OFFLINE_HARD" || true ;;
      back) px_set 1000 "$from=ONLINE $to=OFFLINE_HARD" || true ;;
    esac
    if [[ -n "$SETTLED" ]] && ((SETTLE_FIRST_MS == 0)); then _now; SETTLE_FIRST_MS=$NOW; fi
    if [[ "$SETTLED" == forward ]] && px_state "$from" 1000 && px_all OFFLINE_HARD && px_state "$to" 1000 && ! px_any OFFLINE_HARD && ! px_any OFFLINE_SOFT; then return 0; fi
    if [[ "$SETTLED" == back ]] && px_state "$from" 1000 && ! px_any OFFLINE_HARD && ! px_any OFFLINE_SOFT && px_state "$to" 1000 && px_all OFFLINE_HARD; then return 0; fi
    _now
    if ((NOW >= end)); then
      px_state "$from" 1000 || true
      log "노드를 맞추지 못했다(${SETTLED:-판단 못 함}). $from: $(px_state_text)"
      px_state "$to" 1000 || true
      log "  $to: $(px_state_text)"
      return 1
    fi
    sleep 0.2
  done
}

# ── 한 번에 하나만 ─────────────────────────────────────────
# 쓰기를 바꾸는 단계(10 ~ 70)는 같은 곳에서 동시에 돌지 않게 잠근다. 전환 도중 recover 를 겹쳐 돌리면 두 실행이 노드를
# 서로 반대로 실을 수 있다. 잠금은 실행 중인 프로세스 번호로 하고, 그 프로세스가 없으면(강제로 죽었으면) 넘겨받는다.
runbook_lock() {
  local dir="$WORK_DIR/runbook.lock" other me i
  mkdir -p "$WORK_DIR"
  me="$$ $(_proc_start $$)"
  for i in 1 2 3; do
    if mkdir "$dir" 2>/dev/null; then
      printf '%s\n' "$me" >"$dir/pid.tmp" && mv "$dir/pid.tmp" "$dir/pid"
      echo "${0##*/} $*" >"$dir/what"
      _LOCKED="$dir"
      return 0
    fi
    other=$(cat "$dir/pid" 2>/dev/null || true)
    if [[ -z "$other" ]]; then sleep 0.3; continue; fi # 막 잡은 실행이 아직 pid 를 쓰는 중
    if [[ "$(_proc_start "${other%% *}")" == "${other#* }" ]]; then
      die "다른 런북 실행(pid ${other%% *}, $(cat "$dir/what" 2>/dev/null))이 아직 돈다. 끝났는지 확인한 뒤 다시 한다(그 프로세스가 없는데 이 말이 나오면 $dir 을 지운다)"
    fi
    # 남은 잠금을 다른 이름으로 옮긴 뒤(원자적) 옮긴 것이 본 그 잠금인지 확인한다. 아니면 그사이 다른 실행이 잡은 것이라 돌려놓는다
    if mv "$dir" "$dir.stale.$$" 2>/dev/null; then
      if [[ "$(cat "$dir.stale.$$/pid" 2>/dev/null || true)" == "$other" ]]; then
        log "끝나지 않고 남은 잠금(pid ${other%% *})을 넘겨받는다"
        rm -rf "$dir.stale.$$"
      else
        mv "$dir.stale.$$" "$dir" 2>/dev/null || rm -rf "$dir.stale.$$"
      fi
    fi
  done
  die "잠금을 잡지 못했다($dir). 다른 실행이 없는 것을 확인했다면 이 디렉터리를 지운다"
}
_proc_start() { awk '{print $22}' "/proc/$1/stat" 2>/dev/null || echo gone; } # pid 가 다시 쓰여도 구분되게 시작 시각을 함께 본다
_LOCKED=""

# 리허설은 운영과 다른 호스트그룹(PROXYSQL_HOSTGROUP)에서 돌고, 운영의 쓰기 대상 · 복제 시작점 기록(SSM)을 건드리면 안 된다.
# 운영 호스트그룹(PROXYSQL_PROD_HOSTGROUP, 기본 10)이 아니면 SSM 기록을 받지 않는다(파일만 쓴다)
is_rehearsal() { [[ "$PX_HG" != "${PROXYSQL_PROD_HOSTGROUP:-10}" ]]; }
guard_rehearsal() {
  is_rehearsal || return 0
  [[ -z "${WRITER_SSM_PARAM:-}" && -z "${COORDS_SSM_PARAM:-}" ]] ||
    die "호스트그룹 $PX_HG 는 리허설이다. 운영 SSM 기록(WRITER_SSM_PARAM · COORDS_SSM_PARAM)을 쓰지 않는다(WRITER_FILE · COORDS_FILE 을 준다)"
  log "리허설: 호스트그룹 $PX_HG, 기록은 파일 ${WRITER_FILE:-} ${COORDS_FILE:-}"
}

# ── 현재 쓰기 대상 기록 ─────────────────────────────────────
# 운영은 SSM 파라미터(ProxySQL 태스크가 시작할 때 이 값으로 설정을 만든다), 로컬은 파일. 값은 ncp · rds · switching-<방향>.
# switching-rds(60 전환) · switching-ncp(70 되돌리기)는 그 런북이 도는 동안의 값이다. 그사이 새로 뜨는 ProxySQL 태스크는 설정을
# 만들지 못해 트래픽을 받지 않는다(어느 쪽이 쓰기 대상인지 모르는 노드가 옛 서버로 쓰지 않게). 끝나면 실제 쓰기 대상으로 바꾼다.
# 방향을 남겨 두어, 끊긴 뒤 다른 스크립트의 recover 로 맞추는 실수를 막는다.
record_writer() { # record_writer <ncp|rds|switching-ncp|switching-rds>
  [[ "$1" =~ ^(ncp|rds|switching-ncp|switching-rds)$ ]] || die "쓰기 대상 값이 이상하다: $1"
  if [[ -n "${WRITER_SSM_PARAM:-}" ]]; then
    timeout 20 aws ssm put-parameter --name "$WRITER_SSM_PARAM" --type String --overwrite --value "$1" >/dev/null
  elif [[ -n "${WRITER_FILE:-}" ]]; then
    printf '%s\n' "$1" >"$WRITER_FILE"
  else
    die "WRITER_SSM_PARAM · WRITER_FILE 중 하나가 있어야 한다"
  fi
}
read_writer() {
  if [[ -n "${WRITER_SSM_PARAM:-}" ]]; then
    timeout 20 aws ssm get-parameter --name "$WRITER_SSM_PARAM" --query Parameter.Value --output text
  else
    cat "$WRITER_FILE"
  fi
}

# ── 덤프 때의 복제 시작점 ───────────────────────────────────
# 30 이 남기고 40 · 60 이 읽는다. 덤프와 전환 사이는 몇 주일 수 있어 파일과 함께 SSM 에도 남긴다(COORDS_SSM_PARAM).
# 읽을 때는 source 하지 않고 형식을 검사한다(값이 셸 코드로 실행되지 않게).
coords_save() { # coords_save <binlog 파일> <위치> <GTID 집합>
  local text
  text=$(printf 'DUMP_BINLOG_FILE=%s\nDUMP_BINLOG_POS=%s\nDUMP_GTID_EXECUTED=%s\n' "$1" "$2" "$3")
  _coords_check "$text" || die "복제 시작점 형식이 이상하다: $text"
  printf '%s\n' "$text" >"${COORDS_FILE:-$WORK_DIR/dump-coords.env}"
  if [[ -n "${COORDS_SSM_PARAM:-}" ]]; then
    timeout 20 aws ssm put-parameter --name "$COORDS_SSM_PARAM" --type String --overwrite --value "$text" >/dev/null
  fi
}
# shellcheck disable=SC2034 # 부르는 스크립트가 쓴다
coords_load() { # DUMP_BINLOG_FILE · DUMP_BINLOG_POS · DUMP_GTID_EXECUTED 를 채운다. SSM 이 있으면 SSM 을 믿는다
  local text
  if [[ -n "${COORDS_SSM_PARAM:-}" ]]; then
    text=$(timeout 20 aws ssm get-parameter --name "$COORDS_SSM_PARAM" --query Parameter.Value --output text) || die "SSM $COORDS_SSM_PARAM 읽기 실패"
  else
    text=$(cat "${COORDS_FILE:-$WORK_DIR/dump-coords.env}") || die "복제 시작점 파일이 없다"
  fi
  _coords_check "$text" || die "복제 시작점 형식이 이상하다"
  DUMP_BINLOG_FILE=$(sed -n 's/^DUMP_BINLOG_FILE=//p' <<<"$text")
  DUMP_BINLOG_POS=$(sed -n 's/^DUMP_BINLOG_POS=//p' <<<"$text")
  DUMP_GTID_EXECUTED=$(sed -n 's/^DUMP_GTID_EXECUTED=//p' <<<"$text")
}
_coords_check() {
  grep -Eq '^DUMP_BINLOG_FILE=[A-Za-z0-9._-]+$' <<<"$1" &&
    grep -Eq '^DUMP_BINLOG_POS=[0-9]+$' <<<"$1" &&
    grep -Eq '^DUMP_GTID_EXECUTED=[0-9a-f:,-]+$' <<<"$1" &&
    (($(wc -l <<<"$1") == 3))
}

# SQL · JS 문자열에 넣는 이름(서버 주소 · 계정 · DB)은 영문 · 숫자 · . _ - 만 받는다
ident_ok() { local v; for v in "$@"; do [[ "${!v:-}" =~ ^[A-Za-z0-9._:\ -]*$ ]] || die "$v 에 쓸 수 없는 문자가 있다"; done; }

# ── 계정 확인 ───────────────────────────────────────────────
# ACCOUNTS("계정:단계 ...")와 PW_<계정> 으로 그 서버에 실제로 로그인되는지 본다. 전환 뒤 앱이 RDS 에 붙을 수 있는지 미리 안다
check_logins() { # check_logins <host> <port>
  local entry u v bad=""
  for entry in $ACCOUNTS; do
    u=${entry%%:*}
    v="PW_${u^^}"
    [[ -n "${!v:-}" ]] || die "$v 가 비어 있습니다"
    [[ "$(_mysql "$1" "$2" "$u" "${!v}" REQUIRED <<<"SELECT CURRENT_USER()" 2>/dev/null)" == "$u@%" ]] || bad+="$u "
  done
  [[ -z "$bad" ]] || die "$1 에 로그인되지 않는 계정: $bad"
}

# 시험용 끼어들기 지점(로컬 실패 주입). FAULT_POINT 가 그 이름이면 요청 파일을 만들고 처리될 때까지 기다린다. 운영에서는 비워 둔다
fault_point() {
  [[ "${FAULT_POINT:-}" == "$1" && -n "${FAULT_DIR:-}" ]] || return 0
  FAULT_POINT="" # 한 번만 끼어든다(다시 시도할 때는 그대로 지나간다)
  log "시험: 끼어들기 지점 $1"
  : >"$FAULT_DIR/request"
  local i
  for i in $(seq 300); do
    [[ -e "$FAULT_DIR/request" ]] || return 0
    sleep 0.05
  done
  log "시험: 끼어들기 처리를 기다리다 넘어갔다"
}
