#!/usr/bin/env bash
# 공용 파일을 리프 스택에 심볼릭 링크로 연결한다.
#
#   scripts/link-global.sh terraform/aws/<서비스>/<계정|VPC>[/<리전>] [추가 파일...]
#   scripts/link-global.sh terraform/ncp/<서비스>/... [추가 파일...]
#
# 항상 링크하는 것
#   terraform/<aws|ncp>/version.tf · provider.tf      (ncp 스택도 시크릿과 원격 상태 때문에 AWS provider 를 쓴다)
#   terraform/variables/var_global.tf · locals_global.tf · global.auto.tfvars
#
# 필요하면 인자로 더 넘긴다 (확장자 없이)
#   locals_services        서비스 목록(terraform/application)을 쓰는 스택
#   remote_state_global    다른 스택 output 을 읽는 스택 (local.remote_state.<스택>)
#   provider_us_east_1     CloudFront · 글로벌 WAF 를 다루는 스택 (aws)
set -euo pipefail

leaf="${1:?리프 디렉터리를 지정하세요 (예: terraform/aws/vpc/nova_apnortheast2)}"
shift || true

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
leaf_abs="$root/${leaf#./}"
mkdir -p "$leaf_abs"

case "$leaf" in
  *terraform/ncp/*) cloud=ncp ;;
  *terraform/aws/*) cloud=aws ;;
  *) echo "terraform/aws/... 또는 terraform/ncp/... 아래여야 합니다: $leaf" >&2; exit 1 ;;
esac

link() { # link <terraform/ 기준 경로> <리프 안의 이름>
  ln -sfn "$(realpath --relative-to="$leaf_abs" "$root/terraform/$1")" "$leaf_abs/$2"
  echo "linked $leaf/$2 -> terraform/$1"
}

link "$cloud/version.tf" version.tf
link aws/provider.tf provider.tf
[[ $cloud == ncp ]] && link ncp/provider.tf provider_ncp.tf
link variables/var_global.tf var_global.tf
link variables/locals_global.tf locals_global.tf
link variables/global.auto.tfvars global.auto.tfvars

for f in "$@"; do
  if [[ -f "$root/terraform/variables/$f.tf" ]]; then
    link "variables/$f.tf" "$f.tf"
  elif [[ -f "$root/terraform/$cloud/$f.tf" ]]; then
    link "$cloud/$f.tf" "$f.tf"
  else
    echo "공유 파일이 없습니다: $f" >&2; exit 1
  fi
done
