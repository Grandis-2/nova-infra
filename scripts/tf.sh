#!/usr/bin/env bash
# .env 를 읽어 환경변수로 내보낸 뒤 terraform 을 실행한다.
#
#   scripts/tf.sh <스택 경로> <terraform 명령...>
#
# 예)
#   scripts/tf.sh aws/vpc/nova_apnortheast2 init
#   scripts/tf.sh aws/vpc/nova_apnortheast2 plan
#   scripts/tf.sh aws/vpc/nova_apnortheast2 apply      (관리자 세션 + TF_ALLOW_LOCAL_WRITE=1 일 때만)
#   scripts/tf.sh ncp/database/grandis-nova/kr plan
#
# backend 블록에는 변수를 쓸 수 없어 bucket/region 을 .env 의 TF_BACKEND_* 에서 -backend-config 로 넘긴다.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
stack="${1:?스택 경로를 지정하세요 (예: aws/vpc/nova_apnortheast2, ncp/database/grandis-nova/kr)}"
shift

# aws/ 를 생략하면 terraform/aws 아래에서 찾는다 (vpc/nova_apnortheast2 → terraform/aws/vpc/nova_apnortheast2)
stack="${stack#terraform/}"
dir="$root/terraform/$stack"
[[ -d "$dir" ]] || dir="$root/terraform/aws/$stack"
[[ -d "$dir" ]] || { echo "스택 디렉터리가 없습니다: terraform/$stack 또는 terraform/aws/$stack" >&2; exit 1; }

env_file="${TF_ENV_FILE:-$root/.env}"
if [[ -f "$env_file" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$env_file"
  set +a
else
  echo "경고: $env_file 이 없습니다. .env.example 을 복사해 만드세요." >&2
fi

# 관리자 세션 자격증명이 환경변수에 있으면 AWS_PROFILE 을 지운다.
# 남겨 두면 provider 가 .env 의 프로필(읽기 전용 역할)을 먼저 쓴다.
if [[ -n "${AWS_ACCESS_KEY_ID:-}" ]]; then
  unset AWS_PROFILE
fi

# 인프라 변경은 PR → Atlantis 로만 한다. 막는 건 IAM(읽기 전용 역할)이고, 여기서는 apply 를 시작도 하지 않게 해서
# 도중에 AccessDenied 로 멈추는 일을 없앤다. 최초 구축 때만 TF_ALLOW_LOCAL_WRITE=1 로 푼다.
case "${1:-} ${2:-}" in
  "apply "* | "destroy "* | "import "* | "taint "* | "untaint "* | "force-unlock "* | \
    "state mv" | "state rm" | "state push" | "state replace-provider" | "workspace new" | "workspace delete")
    if [[ "${TF_ALLOW_LOCAL_WRITE:-0}" != "1" ]]; then
      echo "로컬에서는 '$1' 을 실행할 수 없습니다. PR 을 올려 Atlantis 로 적용하세요." >&2
      echo "(최초 구축 같은 예외에만 TF_ALLOW_LOCAL_WRITE=1 을 쓰세요)" >&2
      exit 1
    fi
    if [[ -z "${AWS_ACCESS_KEY_ID:-}" ]]; then
      echo "'$1' 은 관리자 세션에서만 실행할 수 있습니다:" >&2
      echo '  eval "$(aws configure export-credentials --profile infra-admin --format env)"' >&2
      exit 1
    fi
    ;;
esac

: "${TF_BACKEND_BUCKET:?.env 에 TF_BACKEND_BUCKET 을 설정하세요}"
: "${TF_BACKEND_REGION:=ap-northeast-2}"

# init 에만 backend 설정을 붙인다.
export TF_CLI_ARGS_init="-backend-config=bucket=${TF_BACKEND_BUCKET} -backend-config=region=${TF_BACKEND_REGION} ${TF_CLI_ARGS_init:-}"

exec terraform -chdir="$dir" "$@"
