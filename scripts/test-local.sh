#!/usr/bin/env bash
# floci(로컬 AWS 에뮬레이터)에 실제로 apply 해서 설정이 동작하는지 확인한다.
#
#   ./scripts/test-local.sh              전체
#   ./scripts/test-local.sh vpc securitygroup  지정한 스택만 (이름은 stack_dir 참고)
#
# 요금 없이 문법 · 참조 · 리소스 인자가 실제 API 호출까지 통과하는지 본다.
# 에뮬레이터가 구현하지 않은 API 는 실패할 수 있다.
# NCP 는 에뮬레이터가 없다. database 는 출력만 같은 가짜 스택으로 대신하고, 실제 설정은 plan 으로 확인한다.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# 프로바이더 바이너리를 실행해야 하므로 noexec 일 수 있는 /tmp 대신 홈 아래에 둔다
work="${FLOCI_WORKDIR:-$HOME/.cache/floci-tf}"
# *.localhost 는 DNS 로 풀리지 않아 가상 호스트 방식 호출이 깨진다.
# 와일드카드로 127.0.0.1 을 가리키는 localhost.localstack.cloud 를 쓴다.
endpoint="${FLOCI_ENDPOINT:-http://localhost.localstack.cloud:4566}"
bucket="floci-tfstate"

stacks=("$@")
fresh=0
if [[ ${#stacks[@]} -eq 0 ]]; then
  # 인자 없이 돌리면 처음부터 다시 만든다. 기존 리소스 위에 다시 apply 하면 에뮬레이터 응답이 들쭉날쭉하다.
  fresh=1
  # 에뮬레이터가 API 를 지원하지 않아 기본 목록에서 뺀 스택 (필요하면 인자로 지정한다)
  #   edge    : CloudFront 관리형 캐시 정책 조회 불가
  #   bastion : EC2 인스턴스 타입 정보 없음
  stacks=(sops vpc securitygroup s3 sqs ecr database elasticache acm cdn secretsmanager iam ecs scheduler monitoring)
fi

# 실제 계정으로 요청이 새지 않도록 가짜 자격증명을 고정하고, ~/.aws 의 프로필과 SSO 캐시도 읽지 못하게 막는다.
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
unset AWS_SESSION_TOKEN AWS_SECURITY_TOKEN AWS_ROLE_ARN AWS_WEB_IDENTITY_TOKEN_FILE
export AWS_CONFIG_FILE=/dev/null
export AWS_SHARED_CREDENTIALS_FILE=/dev/null
export AWS_REGION=ap-northeast-2
export AWS_DEFAULT_REGION=ap-northeast-2
export AWS_ENDPOINT_URL="$endpoint"
export AWS_ENDPOINT_URL_S3="$endpoint"
unset AWS_PROFILE

if [[ $fresh -eq 1 ]]; then
  docker rm -f floci >/dev/null 2>&1 || true
  rm -rf "$work"
fi

if ! curl -s --max-time 3 "$endpoint" >/dev/null 2>&1; then
  echo "floci 를 띄웁니다..."
  docker rm -f floci >/dev/null 2>&1 || true
  docker run -d --name floci -p 4566:4566 floci/floci:latest >/dev/null || {
    echo "floci 컨테이너를 띄우지 못했습니다." >&2
    exit 1
  }
  for _ in $(seq 30); do
    curl -s --max-time 2 "$endpoint" >/dev/null 2>&1 && break
    sleep 1
  done
fi

# 안전장치: 에뮬레이터 계정(000000000000)이 아니면 멈춘다.
account="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
if [[ "$account" != "000000000000" ]]; then
  echo "중단: 에뮬레이터 계정이 아닙니다 (account=${account:-조회 실패}). 실제 AWS 에 적용될 수 있습니다." >&2
  exit 1
fi
echo "대상: $endpoint (account $account)"

aws s3 mb "s3://$bucket" >/dev/null 2>&1 || true

# 에뮬레이터에는 CloudFront 관리형 prefix list 가 없어 아무 prefix list 로 대신한다.
export TF_VAR_cloudfront_prefix_list_id="$(
  aws ec2 describe-managed-prefix-lists \
    --query 'PrefixLists[0].PrefixListId' --output text 2>/dev/null
)"

# 최신 AMI 공개 SSM 파라미터가 없고 /aws/ 이름은 직접 만들 수도 없어 AMI 를 변수로 넘긴다.
export TF_VAR_ami_id="$(aws ec2 describe-images --query 'Images[0].ImageId' --output text 2>/dev/null)"
[[ "$TF_VAR_ami_id" == "None" || -z "$TF_VAR_ami_id" ]] && export TF_VAR_ami_id="ami-0123456789abcdef0"

# 테스트용 변수. .env 는 읽지 않는다.
export TF_VAR_tfstate_bucket="$bucket"
export TF_VAR_product=nova
export TF_VAR_env=prod
export TF_VAR_aws_region=ap-northeast-2
export TF_VAR_assume_role_arn=""
export TF_VAR_terraform_actor=floci
export TF_VAR_github_repositories='["Grandis-2/be"]'
# 스택을 복사본 폴더에서 돌리므로 서비스 정의 폴더 위치를 직접 넘긴다.
# 서비스 비밀(secrets.sops.yml)은 실제 KMS 로 암호화돼 있어 풀 수 없다 — 비밀 파일을 뺀 복사본을 쓴다
export TF_VAR_application_dir="$work/_application"
export TF_VAR_alert_emails='[]'
export TF_VAR_enable_deletion_protection=false
export TF_VAR_enable_alb_access_logs=false

mkdir -p "$work"

# 프로바이더는 한 번만 받아 모든 스택이 링크로 쓴다. 캐시가 없으면 스택마다 수백 MB 씩 받는다.
export TF_PLUGIN_CACHE_DIR="${TF_PLUGIN_CACHE_DIR:-$HOME/.cache/terraform-plugins}"
mkdir -p "$TF_PLUGIN_CACHE_DIR"
# 잠금 파일이 없는 새 스택도 캐시를 쓰게 한다. 이 시험에서만 켠다
export TF_PLUGIN_CACHE_MAY_BREAK_DEPENDENCY_LOCK_FILE=true

fail=0
# 스택 이름 -> 폴더 (이름은 remote_state 키와 같다)
declare -A stack_dir=(
  [sops]=aws/kms/grandis-nova/ap-northeast-2
  [vpc]=aws/vpc/nova_apnortheast2
  [securitygroup]=aws/securitygroup/nova_apnortheast2
  [s3]=aws/s3/grandis-nova
  [sqs]=aws/sqs/grandis-nova/ap-northeast-2
  [ecr]=aws/ecr/grandis-nova/ap-northeast-2
  [acm]=aws/acm/grandis-nova/ap-northeast-2
  [secretsmanager]=aws/secretsmanager/grandis-nova/ap-northeast-2
  [elasticache]=aws/elasticache/nova_apnortheast2
  [iam]=aws/iam/grandis-nova
  [ecs]=aws/ecs/nova_apnortheast2
  [scheduler]=aws/scheduler/nova_apnortheast2
  [monitoring]=aws/monitoring/nova_apnortheast2
  [bastion]=aws/bastion/nova_apnortheast2
  [edge]=aws/edge/grandis-nova
  [cdn]=aws/cdn/grandis-nova
  [init]=aws/init/grandis-nova
)

rm -rf "$work/_application" && cp -r "$root/terraform/application" "$work/_application"
# 모듈 복사본은 매 실행마다 새로 만든다 (스택을 골라 돌릴 때 옛 모듈로 시험하지 않게)
rm -rf "$work/_mods"
find "$work/_application" \( -name 'secrets.sops.yml' -o -name 'secret.yml' \) -delete

for stack in "${stacks[@]}"; do
  if [[ "$stack" == "database" ]]; then
    src=""   # 아래에서 가짜 스택을 만든다
  elif [[ -n "${stack_dir[$stack]:-}" ]]; then
    src="$root/terraform/${stack_dir[$stack]}"
  else
    echo "알 수 없는 스택입니다: $stack" >&2; exit 1
  fi
  dst="$work/$stack"
  # 원본을 건드리지 않도록 심볼릭 링크를 실제 파일로 풀어 복사한다
  mkdir -p "$dst"
  if [[ -z "$src" ]]; then
    # NCP database 대신 출력만 같은 가짜 스택을 만든다 (서비스별 DB 시크릿만 생성)
    for f in var_global locals_global locals_services; do cp "$root/terraform/variables/$f.tf" "$dst/"; done
    cp "$root/terraform/aws/provider.tf" "$root/terraform/aws/version.tf" "$dst/"
    cat >"$dst/main.tf" <<'TF'
locals {
  db_services = { for k, v in local.services : k => v if v.db != null }
}
resource "aws_secretsmanager_secret" "service" {
  for_each = local.db_services
  name     = "${local.name_prefix}/db/app/${each.value.name}"
}
output "db_address" { value = "ncp-db.floci.test" }
output "db_port" { value = 3306 }
output "app_secret_arns" { value = { for k, s in aws_secretsmanager_secret.service : k => s.arn } }
TF
  else
    [[ -d "$src" ]] || { echo "== $stack"; echo "   FAIL  스택 폴더가 없습니다: $src"; fail=1; continue; }
    cp -rL "$src/." "$dst/" 2>/dev/null || { echo "== $stack"; echo "   FAIL  복사에 실패했습니다: $src"; fail=1; continue; }
  fi
  # 함께 복사된 .terraform 은 지운다. init 이 캐시에서 링크한다
  rm -rf "$dst/.terraform"
  rm -f "$dst/backend.tf"
  # *.auto.tfvars 가 TF_VAR_* 보다 우선하므로 지워서 테스트용 값을 쓰게 한다
  rm -f "$dst/global.auto.tfvars"
  # 아래 zz-floci.auto.tfvars 는 커밋된 terraform.tfvars 를 덮어쓴다.
  # NAT 인스턴스(fck-nat)는 ENI source/dest check 변경을 지원하지 않아 게이트웨이로 시험한다
  [[ "$stack" == "vpc" ]] && echo 'nat_mode = "gateway"' >"$dst/zz-floci.auto.tfvars"
  # Route 53 영역과 ACM 검증이 돌지 않아 도메인 없이(HTTP) 시험한다
  [[ "$stack" == "acm" || "$stack" == "cdn" ]] && echo 'domain_name = ""' >"$dst/zz-floci.auto.tfvars"
  # 실제 계정의 ECR 저장소를 import 하는 블록은 에뮬레이터에서 실패한다
  [[ "$stack" == "ecr" ]] && echo 'existing_repositories = []' >"$dst/zz-floci.auto.tfvars"
  # 실제 계정에는 GitHub OIDC 공급자가 이미 있어 조회해서 쓰지만, 에뮬레이터에는 없으므로 만든다
  [[ "$stack" == "iam" ]] && echo 'create_github_oidc_provider = true' >"$dst/zz-floci.auto.tfvars"
  [[ "$stack" == "securitygroup" ]] && echo 'alb_origin_https = false' >"$dst/zz-floci.auto.tfvars"

  # 에뮬레이터는 가상 호스트 방식 버킷 주소를 받지 못해 path 스타일로 바꾼다.
  sed -i 's|^  region = var.aws_region$|  region            = var.aws_region\n  s3_use_path_style = true|' "$dst/provider.tf"

  # 로컬 모듈(source = "../...")도 작업 폴더로 복사하고 그 복사본을 가리키게 한다 (아래에서 태그를 빼야 한다)
  if [[ -n "$src" ]]; then
    python3 - "$src" "$dst" "$work/_mods" <<'PY'
import os, re, shutil, sys, glob
src, dst, mods = sys.argv[1:]
pat = re.compile(r'(source\s*=\s*")(\.\.?/[^"]+)(")')
for f in glob.glob(os.path.join(dst, "*.tf")):
    s = open(f).read()
    def fix(m):
        orig = os.path.normpath(os.path.join(src, m.group(2)))
        copy = os.path.join(mods, orig.strip("/").replace("/", "__"))
        if not os.path.isdir(copy):
            shutil.copytree(orig, copy, symlinks=False, ignore=shutil.ignore_patterns(".terraform"))
        return m.group(1) + copy + m.group(3)
    open(f, "w").write(pat.sub(fix, s))
PY
  fi

  # floci 는 일부 서비스의 태그 API 를 구현하지 않는다. 태그는 메타데이터라 복사본에서 뺀다
  python3 -I - "$dst"/*.tf $(find "$work/_mods" -name '*.tf' 2>/dev/null) <<'PY'
import re, sys
start = re.compile(r'^(\s*)(default_tags\s*\{|tags\s*=\s*\{|tags\s*=\s*merge\()\s*$')
oneline = re.compile(r'^\s*tags\s*=\s*\{[^{}]*\}\s*$')
for path in sys.argv[1:]:
    try:
        lines = open(path).read().splitlines()
    except FileNotFoundError:  # 글롭이 아무것도 못 찾으면 패턴 문자열이 그대로 넘어온다
        continue
    out, i = [], 0
    while i < len(lines):
        if oneline.match(lines[i]):
            i += 1
            continue
        m = start.match(lines[i])
        if m:
            depth = m.group(2).count("{") + m.group(2).count("(")
            i += 1
            while i < len(lines) and depth > 0:
                depth += lines[i].count("{") + lines[i].count("(") - lines[i].count("}") - lines[i].count(")")
                i += 1
            continue
        out.append(lines[i])
        i += 1
    open(path, "w").write("\n".join(out) + "\n")
PY

  # 다른 스택 output 은 로컬 상태 파일에서 읽는다
  if [[ -f "$dst/remote_state.tf" ]]; then
    sed -i "s|backend = \"s3\"|backend = \"local\"|g" "$dst/remote_state.tf"
    python3 - "$dst/remote_state.tf" "$work" <<'PY'
import re, sys
path, work = sys.argv[1], sys.argv[2]
s = open(path).read()
# config = local.remote_state.<스택> → 작업 폴더의 로컬 상태 파일
s = re.sub(
    r'config\s*=\s*local\.remote_state\.([a-z0-9_-]+)',
    lambda m: 'config  = { path = "%s/%s/terraform.tfstate" }' % (work, m.group(1)),
    s,
)
open(path, 'w').write(s)
PY
  fi

  echo "== $stack"
  # init 스택은 상태 버킷을 만드는 스택이라 기존 이름을 주면 충돌한다
  if [[ "$stack" == "init" ]]; then
    export TF_VAR_tfstate_bucket="${bucket}-init"
  else
    export TF_VAR_tfstate_bucket="$bucket"
  fi

  if terraform -chdir="$dst" init -input=false >/dev/null 2>&1 &&
     out=$(terraform -chdir="$dst" apply -auto-approve -input=false -no-color 2>&1); then
    echo "   ok  리소스 $(terraform -chdir="$dst" state list 2>/dev/null | wc -l)개"
  else
    echo "   FAIL"
    tail -25 <<<"${out:-init 실패}" | sed 's/^/        /'
    fail=1
  fi
done

echo
if [[ $fail -eq 0 ]]; then
  echo "모두 통과했습니다. 상태 파일: $work"
  echo "(edge, bastion 은 에뮬레이터가 API 를 지원하지 않아 기본 목록에서 뺐습니다)"
else
  echo "실패한 스택이 있습니다. 위 출력을 확인하세요."
fi
exit $fail
