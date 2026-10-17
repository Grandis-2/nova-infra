#!/usr/bin/env python3
"""be 의 API 와 ALB 경로 규칙 · WAF 본문 상한을 대조한다.

be 는 새 API 를 인프라에 알리지 않는다. 그래서 be 소스의 컨트롤러 매핑을 모두 뽑아
terraform/application/*/service.yml 의 routes 에 ALB 와 같은 방식(우선순위 · 와일드카드 · 메서드)으로 대 본다.

  다른 서비스로 가는 API   ALB 규칙이 다른 서비스의 경로를 먼저 잡는다
  규칙이 없는 API          어느 규칙에도 걸리지 않아 ALB 가 404 로 끝낸다
  본문 상한을 넘을 수 있는 API  요청 타입의 @Size 상한으로 셈한 최대 본문이 WAF 상한(공개 8KB, 관리자 512KB)을 넘는다

사용: route_check.py --be <be 저장소 경로> [--infra <이 저장소 경로>] [--report <markdown 파일>]
문제가 있으면 종료 코드 1.
"""
import argparse
import pathlib
import re
import sys

import yaml

# 의도한 예외. (메서드, 경로) → 실제로 받는 서비스
ALLOWED = {
    ("POST", "/api/v1/preorders"): "waitingroom",  # 대기열 입장 판정 뒤 preorder 로 중계한다 (waitingroom AcceptRoute)
}

PUBLIC_BODY_LIMIT = 8 * 1024  # WAF 관리형 SizeRestrictions_BODY
ADMIN_BODY_LIMIT = 512 * 1024  # edge waf.tf AdminBodyContentLength
ADMIN_PREFIX = "/api/v1/admin/"
ADMIN_LOGIN_PREFIX = "/api/v1/admin/session"  # 토큰 없이 부르므로 공개 상한을 받는다
UPLOAD_PATHS = {"/api/v1/admin/images"}  # 사진(멀티파트) — 본문 상한을 따로 둔다

MAPPING = re.compile(r"@(Get|Post|Put|Patch|Delete|Request)Mapping\s*(\((?:[^()]|\([^()]*\))*\))?")
CONST = re.compile(r"static\s+final\s+(?:String|int|long)\s+(\w+)\s*=\s*(\"[^\"]*\"|[\d_]+)\s*;")


def load_sources(be: pathlib.Path) -> dict[str, str]:
    return {str(p.relative_to(be)): p.read_text(encoding="utf-8", errors="replace")
            for p in be.glob("*/src/main/**/*.java")}


def collect_constants(sources: dict[str, str]) -> dict[str, str]:
    consts: dict[str, str] = {}
    for src in sources.values():
        cls = re.search(r"\b(?:class|record|interface|enum)\s+(\w+)", src)
        name = cls.group(1) if cls else ""
        for key, value in CONST.findall(src):
            value = value.replace("_", "") if not value.startswith('"') else value
            consts[f"{name}.{key}"] = value
            consts.setdefault(key, value)
    return consts


def resolve(text: str, consts: dict[str, str]) -> str:
    """애너테이션 인자의 상수(BASE_PATH, Foo.MAX)를 값으로 바꾼다. 문자열 안은 건드리지 않는다"""
    parts = re.split(r"(\"[^\"]*\")", text)
    for i in range(0, len(parts), 2):
        parts[i] = re.sub(r"\b((?:[A-Z]\w*\.)?[A-Z_][A-Z0-9_]+)\b",
                          lambda m: consts.get(m.group(1), m.group(1)), parts[i])
    return "".join(parts)


def mapping_paths(args: str | None, consts: dict[str, str]) -> list[str]:
    if not args:
        return [""]
    inner = resolve(args[1:-1], consts)
    named = re.search(r"(?:value|path)\s*=\s*(\{[^}]*\}|\"[^\"]*\")", inner)
    target = named.group(1) if named else (inner if inner.strip().startswith(("\"", "{")) else "")
    return re.findall(r"\"([^\"]*)\"", target) or [""]


def mapping_methods(kind: str, args: str | None) -> list[str]:
    if kind != "Request":
        return [kind.upper()]
    return re.findall(r"RequestMethod\.(\w+)", args or "") or ["ANY"]


def endpoints(sources: dict[str, str], consts: dict[str, str]) -> list[dict]:
    out = []
    for path, src in sources.items():
        if "@RestController" not in src and "@Controller" not in src:
            continue
        service = path.split("/")[0]
        cls = re.search(r"\bclass\s+\w+", src)
        head, body = (src[:cls.start()], src[cls.start():]) if cls else ("", src)
        bases = [""]
        for m in MAPPING.finditer(head):
            if m.group(1) == "Request":
                bases = mapping_paths(m.group(2), consts)
        for m in MAPPING.finditer(body):
            signature = body[m.end():body.find("{", m.end())]
            request_type = re.search(r"@RequestBody\b(?:\s+@\w+(?:\([^)]*\))?)*\s+([A-Z]\w*)", signature)
            body_type = request_type.group(1) if request_type else None
            if body_type in ("String", "JsonNode", "Map"):
                # 본문을 문자열로 받아 직접 파싱하는 API 는 문서용 @Schema(implementation = X.class) 에 실제 타입이 있다
                documented = re.search(r"implementation\s*=\s*(\w+)\.class", signature)
                body_type = documented.group(1) if documented else None
            for base in bases:
                for sub in mapping_paths(m.group(2), consts):
                    full = (base.rstrip("/") + "/" + sub.lstrip("/")).rstrip("/") if sub else base
                    for method in mapping_methods(m.group(1), m.group(2)):
                        out.append({"service": service, "method": method, "path": full or "/",
                                    "body": body_type, "file": path})
    return out


def load_rules(infra: pathlib.Path) -> list[dict]:
    rules = []
    for f in sorted((infra / "terraform/application").glob("*/service.yml")):
        spec = yaml.safe_load(f.read_text(encoding="utf-8")) or {}
        if spec.get("deploy") is False:
            continue
        for r in spec.get("routes") or []:
            rules.append({"service": f.parent.name, "priority": int(r["priority"]), "methods": r.get("methods") or [],
                          "paths": r["paths"],
                          "patterns": [re.compile("^" + re.escape(p).replace(r"\*", ".*").replace(r"\?", ".") + "$")
                                       for p in r["paths"]]})
    return sorted(rules, key=lambda r: r["priority"])


def route(rules: list[dict], method: str, path: str) -> dict | None:
    for r in rules:
        if r["methods"] and method not in r["methods"] and method != "ANY":
            continue
        if any(p.match(path) for p in r["patterns"]):
            return r
    return None


# ── 본문 최대 크기 어림 ──────────────────────────────────────
def find_type(sources: dict[str, str], name: str) -> str | None:
    pattern = re.compile(rf"\b(?:record|class)\s+{name}\b")
    for src in sources.values():
        m = pattern.search(src)
        if m:
            return src[m.start():]
    return None


def max_body(sources: dict[str, str], consts: dict[str, str], name: str, depth: int = 0) -> int:
    """@Size 로 상한이 정해진 필드만 더한다(한글 3바이트, UUID 40바이트). 상한이 없는 필드는 셈하지 않는다"""
    src = find_type(sources, name)
    if not src or depth > 2:
        return 0
    header = src[:src.find("{")] if "record" in src[:20] else src[:src.find("}")]
    total = 0
    for m in re.finditer(r"@Size\(([^)]*)\)\s*(?:@\w+(?:\([^)]*\))?\s*)*(String|List<(.+?)>)\s+\w+", resolve(header, consts)):
        limit = re.search(r"max\s*=\s*([\d_]+)", m.group(1))
        if not limit:
            continue
        n = int(limit.group(1).replace("_", ""))
        if m.group(2) == "String":
            total += n * 3
            continue
        element = m.group(3)
        inner_size = re.search(r"@Size\([^)]*max\s*=\s*([\d_]+)", element)
        inner_type = re.findall(r"([A-Z]\w*)\s*$", element.strip())
        if inner_size:
            total += n * int(inner_size.group(1).replace("_", "")) * 3
        elif inner_type and inner_type[0] == "UUID":
            total += n * 40
        elif inner_type:
            total += n * max(max_body(sources, consts, inner_type[0], depth + 1), 60)
    return total


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--be", required=True, type=pathlib.Path)
    ap.add_argument("--infra", default=pathlib.Path(__file__).resolve().parents[2], type=pathlib.Path)
    ap.add_argument("--report", type=pathlib.Path)
    args = ap.parse_args()

    sources = load_sources(args.be)
    consts = collect_constants(sources)
    rules = load_rules(args.infra)
    apis = [e for e in endpoints(sources, consts) if e["path"].startswith(("/api/", "/.well-known/"))]

    misrouted, unrouted, too_large = [], [], []
    for e in apis:
        concrete = re.sub(r"\{[^}]+\}", "x1", e["path"])
        hit = route(rules, e["method"], concrete)
        target = hit["service"] if hit else None
        if target != e["service"] and ALLOWED.get((e["method"], e["path"])) != target:
            (misrouted if hit else unrouted).append((e, hit))
        if e["body"] and e["path"] not in UPLOAD_PATHS:
            admin = e["path"].startswith(ADMIN_PREFIX) and not e["path"].startswith(ADMIN_LOGIN_PREFIX)
            limit = ADMIN_BODY_LIMIT if admin else PUBLIC_BODY_LIMIT
            size = max_body(sources, consts, e["body"])
            if size > limit:
                too_large.append((e, size, limit))

    lines = [f"# be API 경로 점검", "", f"API {len(apis)}개, ALB 규칙 {len(rules)}개를 대조했다.", ""]
    if misrouted:
        lines += ["## 다른 서비스로 가는 API", "", "| API | 주인 | 실제 (규칙) |", "|---|---|---|"]
        lines += [f"| `{e['method']} {e['path']}` | {e['service']} | {h['service']} (p{h['priority']}) |" for e, h in misrouted]
        lines += [""]
    if unrouted:
        lines += ["## 규칙이 없는 API (ALB 404)", "", "| API | 주인 |", "|---|---|"]
        lines += [f"| `{e['method']} {e['path']}` | {e['service']} |" for e, _ in unrouted]
        lines += [""]
    if too_large:
        lines += ["## WAF 본문 상한을 넘을 수 있는 API", "",
                  "요청 타입의 `@Size` 상한으로 셈한 최대 크기다(한글 3바이트). 상한이 없는 필드는 빠져 있어 실제로는 더 클 수 있다.", "",
                  "| API | 요청 타입 | 최대 (어림) | WAF 상한 |", "|---|---|---|---|"]
        lines += [f"| `{e['method']} {e['path']}` | `{e['body']}` | {s // 1024} KB | {l // 1024} KB |" for e, s, l in too_large]
        lines += [""]
    ok = not (misrouted or unrouted or too_large)
    if ok:
        lines += ["문제 없음."]
    else:
        lines += ["고치는 곳: 경로는 `terraform/application/<서비스>/service.yml` 의 `routes`, 본문 상한은 `terraform/aws/edge/grandis-nova/waf.tf`."]
    report = "\n".join(lines) + "\n"
    print(report)
    if args.report:
        args.report.write_text(report, encoding="utf-8")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
