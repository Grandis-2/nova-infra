#!/usr/bin/env bash
# 최초 1회: 상태 저장용 S3 버킷을 만들고, init 스택 자신의 상태도 그 버킷으로 옮긴다.
#
#   scripts/bootstrap.sh
#
# 1) terraform/aws/init/grandis-nova 를 로컬 상태로 apply → 버킷 생성
# 2) backend.tf 를 활성화하고 init -migrate-state → 상태를 S3 로 이전
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dir="$root/terraform/aws/init/grandis-nova"

env_file="${TF_ENV_FILE:-$root/.env}"
[[ -f "$env_file" ]] || { echo ".env 가 필요합니다. cp .env.example .env" >&2; exit 1; }
set -a; source "$env_file"; set +a
: "${TF_BACKEND_BUCKET:?.env 에 TF_BACKEND_BUCKET 을 설정하세요}"

# 관리자 세션 자격증명이 환경변수에 있으면 AWS_PROFILE 을 지운다.
# 남겨 두면 provider 가 .env 의 프로필(읽기 전용 역할)을 먼저 쓴다.
if [[ -n "${AWS_ACCESS_KEY_ID:-}" ]]; then
  unset AWS_PROFILE
fi

if [[ -z "${AWS_ACCESS_KEY_ID:-}" ]]; then
  echo "관리자 세션이 필요합니다:" >&2
  echo '  eval "$(aws configure export-credentials --profile infra-admin --format env)"' >&2
  exit 1
fi
echo "실행 주체: $(aws sts get-caller-identity --query Arn --output text)"

# 이미 부트스트랩된 계정이면 할 일이 없다 (상태도 이미 S3 에 있다)
if aws s3api head-bucket --bucket "$TF_BACKEND_BUCKET" 2>/dev/null; then
  echo "상태 버킷 ${TF_BACKEND_BUCKET} 이 이미 있습니다. 이후 변경은 scripts/tf.sh aws/init/grandis-nova 로 합니다."
  exit 0
fi

echo "1) 로컬 상태로 상태 저장 버킷을 만듭니다."
# 버킷이 생기기 전에는 S3 backend 를 쓸 수 없으므로 잠시 끈다 (2단계에서 다시 켠다)
[[ -f "$dir/backend.tf" ]] && mv "$dir/backend.tf" "$dir/backend.tf.disabled"
trap '[[ -f "$dir/backend.tf.disabled" ]] && mv "$dir/backend.tf.disabled" "$dir/backend.tf"' EXIT
terraform -chdir="$dir" init -backend=false
terraform -chdir="$dir" apply "$@"

echo
echo "2) init 스택의 상태를 S3 로 옮깁니다."
mv "$dir/backend.tf.disabled" "$dir/backend.tf"
trap - EXIT
terraform -chdir="$dir" init -migrate-state \
  -backend-config="bucket=${TF_BACKEND_BUCKET}" \
  -backend-config="region=${TF_BACKEND_REGION:-ap-northeast-2}"

echo
echo "완료했습니다. 이제부터는 scripts/tf.sh <스택> <명령> 을 쓰세요."
