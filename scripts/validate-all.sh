#!/usr/bin/env bash
# 모든 스택과 모듈에 fmt, validate 를 돌린다. backend 에는 접속하지 않는다.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0

targets=("$root/terraform")

echo "== terraform fmt =="
if ! terraform fmt -recursive -check "${targets[@]}"; then
  echo "  위 파일의 포맷이 맞지 않습니다. terraform fmt -recursive 로 고치세요." >&2
  fail=1
fi

echo
echo "== terraform validate =="
# 임시 폴더를 .terraform 대신 써서 원격 상태와 기존 .terraform 을 건드리지 않는다. 프로바이더는 공유 캐시에서 링크한다.
data_root="$(mktemp -d)"
trap 'rm -rf "$data_root"' EXIT
export TF_PLUGIN_CACHE_DIR="${TF_PLUGIN_CACHE_DIR:-$HOME/.cache/terraform-plugins}"
export TF_PLUGIN_CACHE_MAY_BREAK_DEPENDENCY_LOCK_FILE=true
mkdir -p "$TF_PLUGIN_CACHE_DIR"

while IFS= read -r dir; do
  name="${dir#"$root/"}"
  out=""
  export TF_DATA_DIR="$data_root/${name//\//_}"
  if out=$(terraform -chdir="$dir" init -backend=false -input=false -no-color 2>&1) &&
     out=$(terraform -chdir="$dir" validate -no-color 2>&1); then
    echo "  ok    $name"
  else
    echo "  FAIL  $name"
    echo "$out" | sed 's/^/        /'
    fail=1
  fi
done < <(unset TF_DATA_DIR; find "${targets[@]}" -name '*.tf' -not -path '*/.terraform/*' -not -path '*/terraform/variables/*' -printf '%h\n' \
  | grep -Ev '/terraform/aws$' | sort -u)   # 공용 파일 폴더는 리프가 링크해서 쓰므로 뺀다

exit $fail
