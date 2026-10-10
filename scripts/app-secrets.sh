#!/usr/bin/env bash
# 외부에서 받은 서비스 비밀(카카오, 토스 등)을 암호화하고 다시 푼다.
# 원문은 secret.yml, 암호화본은 secrets.sops.yml 이다.
# Terraform 이 만들 수 있는 비밀(JWT 키 등)은 service.yml 의 generated_secrets 로 둔다 — 여기에 넣지 않는다.
# secret.yml 은 git 에 올라가지 않는다(.gitignore). 커밋하는 것은 secrets.sops.yml 뿐이다.
# 키 이름이 곧 컨테이너 환경변수 이름이다 — 대문자 · 숫자 · _ 만, 인프라가 넣는 이름은 쓸 수 없다.
#
#   scripts/app-secrets.sh encrypt [서비스...]   secret.yml → 검사 → secrets.sops.yml (인자가 없으면 전부)
#   scripts/app-secrets.sh decrypt <서비스...>   secrets.sops.yml → secret.yml (다른 PC 에서 고칠 때)
#
# 관리자 세션에서 실행한다 (sops 가 nova-sops-common 역할을 빌린다).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="$root/terraform/application"
cmd="${1:-}"
shift || true

plain() { echo "$app/$1/secret.yml"; }
enc() { echo "$app/$1/secrets.sops.yml"; }
rel() { echo "${1#"$root"/}"; }

# ── encrypt / decrypt ────────────────────────────────────────
# 키 검사 (ecs 스택의 검사와 같은 규칙)
check_py=$(cat <<'PY'
import re, sys, yaml
name, path = sys.argv[1], sys.argv[2]
doc = yaml.safe_load(open(path))
if not isinstance(doc, dict) or not doc:
    sys.exit(f"  {name}: 비어 있거나 '키: 값' 형식이 아닙니다")
reserved = {"SPRING_PROFILES_ACTIVE", "AWS_REGION", "SPRING_APPLICATION_JSON",
            "SPRING_DATASOURCE_USERNAME", "SPRING_DATASOURCE_PASSWORD"}
bad = []
for k, v in doc.items():
    k = str(k)
    if not re.fullmatch(r"[A-Z_][A-Z0-9_]*", k):
        bad.append(f"  {name}: {k} — 환경변수 이름(대문자, 숫자, _)이어야 합니다")
    elif k in reserved or k.endswith(("_DATASOURCE_USERNAME", "_DATASOURCE_PASSWORD")):
        bad.append(f"  {name}: {k} — 인프라가 넣는 이름이라 쓸 수 없습니다")
    if isinstance(v, (dict, list)):
        bad.append(f"  {name}: {k} — 값은 문자열이어야 합니다")
if bad:
    sys.exit("\n".join(bad))
PY
)

encrypt() {
  local svcs=() rc=0
  if [[ $# -gt 0 ]]; then svcs=("$@"); else
    for f in "$app"/*/secret.yml; do [[ -e "$f" ]] && svcs+=("$(basename "$(dirname "$f")")"); done
  fi
  [[ ${#svcs[@]} -gt 0 ]] || { echo "암호화할 secret.yml 이 없습니다"; return 0; }
  for s in "${svcs[@]}"; do
    [[ -e "$(plain "$s")" ]] || { echo "없음: $(rel "$(plain "$s")")" >&2; rc=1; continue; }
    python3 -I -c "$check_py" "$s" "$(plain "$s")" || { rc=1; continue; }
    (cd "$root" && sops encrypt --filename-override "$(rel "$(enc "$s")")" --input-type yaml --output-type yaml "$(plain "$s")") >"$(enc "$s").tmp"
    grep -q '^sops:' "$(enc "$s").tmp" || { rm -f "$(enc "$s").tmp"; echo "암호화에 실패했습니다: $s" >&2; exit 1; }
    mv "$(enc "$s").tmp" "$(enc "$s")"
    echo "암호화했습니다: $(rel "$(enc "$s")")"
  done
  return $rc
}

decrypt() {
  [[ $# -gt 0 ]] || { echo "서비스 이름을 지정하세요 (예: member)" >&2; exit 1; }
  for s in "$@"; do
    [[ -e "$(enc "$s")" ]] || { echo "없음: $(rel "$(enc "$s")")" >&2; exit 1; }
    [[ -e "$(plain "$s")" ]] && { echo "이미 있습니다: $(rel "$(plain "$s")") — 지우고 다시 실행하세요" >&2; exit 1; }
    (umask 077 && sops decrypt "$(enc "$s")" >"$(plain "$s")")
    echo "풀었습니다: $(rel "$(plain "$s")") (git 에 올라가지 않습니다)"
  done
}

case "$cmd" in
  encrypt | decrypt)
    command -v sops >/dev/null || { echo "sops 가 필요합니다" >&2; exit 1; }
    "$cmd" "$@"
    ;;
  *)
    sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
