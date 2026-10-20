#!/usr/bin/env bash
# 운영자 노트북에서 RDS 이전 런북을 돌리는 도구. 런북 단계는 bastion 에서 SSM Run Command 로 돈다(노트북 연결이 끊겨도 끝까지 간다).
# 비밀번호는 bastion 이 Secrets Manager 에서 직접 읽으므로 여기서는 다루지 않는다. AWS 로그인은 미리 해 둔다.
#
#   scripts/db-migration/ops.sh step <단계> [Args...]   런북 한 단계를 돌리고 끝날 때까지 기다린다. 종료 코드는 그 단계의 것
#                                                       예) ops.sh step 40-replication g2
#                                                           ops.sh step 60-cutover rehearsal nova-rh.example.com
#   scripts/db-migration/ops.sh writer                 쓰기 대상 기록(ncp · rds · switching-*)
#   scripts/db-migration/ops.sh running                bastion 에서 아직 도는 런북 명령
#   scripts/db-migration/ops.sh shell                  bastion 에 접속한다(Session Manager)
#
#   NAME_PREFIX   (기본 nova-prod)   BASTION  bastion 인스턴스 ID (기본: 이름 태그 <NAME_PREFIX>-bastion 으로 찾는다)
#
# 단계 이름은 스크립트 파일 이름에서 .sh 를 뺀 것이다(00-precheck … 70-rollback). 런북 로그는 대부분 표준 오류로 나오고,
# 화면에는 SSM 이 돌려주는 24KB 까지만 보인다. 전체는 CloudWatch Logs(/aws/ssm/<문서 이름>)에 남는다.
# 맥의 bash 3.2 에서도 돈다.
set -euo pipefail
prefix="${NAME_PREFIX:-nova-prod}"

bastion() {
  if [[ -n "${BASTION:-}" ]]; then
    echo "$BASTION"
    return
  fi
  local id
  id=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=$prefix-bastion" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].InstanceId' --output text)
  [[ "$id" =~ ^i-[0-9a-f]+$ ]] || { echo "bastion 을 찾지 못했다($id). BASTION 을 준다" >&2; exit 1; }
  echo "$id"
}

case "${1:-}" in
  step)
    step="${2:?단계 이름(예: 40-replication)}"
    shift 2
    args="$*"
    [[ "$step" =~ ^[0-9][0-9]-[a-z0-9-]+$ ]] || { echo "단계 이름이 이상하다: $step" >&2; exit 1; }
    # SSM 문서가 받는 Args 형식과 같게 검사한다(셸에 그대로 들어간다)
    [[ "$args" =~ ^[a-z0-9\ ._=-]*$ ]] || { echo "Args 에 쓸 수 없는 문자가 있다: $args" >&2; exit 1; }
    id=$(bastion)
    cmd=$(aws ssm send-command --instance-ids "$id" --document-name "$prefix-db-migration-$step" \
      --parameters "{\"Args\":[\"$args\"]}" --cloud-watch-output-config CloudWatchOutputEnabled=true \
      --query Command.CommandId --output text)
    echo "== $step ${args:+($args)} · CommandId $cmd · bastion $id" >&2
    while :; do
      status=$(aws ssm get-command-invocation --command-id "$cmd" --instance-id "$id" --query Status --output text 2>/dev/null || echo Pending)
      case $status in Pending | InProgress | Delayed) sleep 3 ;; *) break ;; esac
    done
    aws ssm get-command-invocation --command-id "$cmd" --instance-id "$id" --query StandardOutputContent --output text
    aws ssm get-command-invocation --command-id "$cmd" --instance-id "$id" --query StandardErrorContent --output text >&2
    code=$(aws ssm get-command-invocation --command-id "$cmd" --instance-id "$id" --query ResponseCode --output text)
    echo "== $status, 종료 코드 $code" >&2
    [[ "$code" =~ ^-?[0-9]+$ ]] || code=1
    ((code >= 0)) || code=1
    exit "$code"
    ;;
  writer)
    aws ssm get-parameter --name "/$prefix/db-migration/writer" --query Parameter.Value --output text
    ;;
  running)
    aws ssm list-commands --instance-id "$(bastion)" --filters key=Status,value=InProgress \
      --query 'Commands[].[CommandId, DocumentName, Parameters.Args[0], RequestedDateTime]' --output text
    ;;
  shell)
    exec aws ssm start-session --target "$(bastion)"
    ;;
  *)
    sed -n '2,15p' "$0" >&2
    exit 1
    ;;
esac
