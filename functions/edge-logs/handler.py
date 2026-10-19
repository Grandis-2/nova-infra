"""ALB · CloudFront 접근 로그를 OTel 게이트웨이로 보낸다.

로그 버킷에 파일이 생기면 그 파일을 읽어 한 줄을 로그 레코드 하나로 바꾸고, OTLP HTTP(JSON)로 게이트웨이에 보낸다.
게이트웨이가 마스킹을 거쳐 Loki 에 넣는다. Loki 라벨은 service_name(alb, cloudfront)이고 나머지 필드는 structured metadata 다.

쿼리 문자열, 쿠키, User-Agent, Referer 는 보내지 않는다. 토큰이나 개인정보가 섞일 수 있고 지연 · 오류 분석에 필요 없다.
사용자 IP 는 대역(IPv4 /24, IPv6 /48)까지만 보낸다. ALB 가 기록하는 클라이언트는 CloudFront 엣지라서 보내지 않는다.

보내다 실패하면 예외를 던져 Lambda 재시도에 맡긴다. 게이트웨이가 일부 레코드만 거절하면 다시 보내지 않고 거절 수만 기록한다.
다시 보내면 이미 받아들인 레코드가 중복되기 때문이다.

파일은 통째로 메모리에 풀지 않고 1MiB 씩 풀어 줄 단위로 처리하고, 레코드는 BATCH 줄씩 보낸다. 부하 시험 때는 ALB 노드 하나의
5분 파일이 수십만 줄(풀면 100MB 이상)이 되어 통째로 들면 메모리가 넘친다. 그러면 같은 파일의 실제 사용자 로그까지 잃는다.
압축된 원본(수십 MB 이하)은 먼저 다 받고 끝까지 풀어 본 뒤에 보내기 시작한다. 읽다가 실패하면 이미 보낸 묶음이 재시도 때 중복되기 때문이다.

부하 시험(Grandis-2/nova-loadtest) 요청 줄은 보내지 않는다. k6 는 User-Agent 를 nova-loadtest/<시험 ID> 로 고정하고, 그 정보는 k6 결과와
겹친다. 시험 중에는 이 줄이 대부분이라 Loki 수집 한도를 넘기지 않게 파싱 전에 버리고 버린 줄 수만 기록한다.
"""

import gzip
import io
import ipaddress
import json
import os
import shlex
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from urllib.parse import unquote, unquote_plus, urlsplit

import boto3

ENDPOINT = os.environ["OTLP_ENDPOINT"].rstrip("/") + "/v1/logs"
ENVIRONMENT = os.environ.get("DEPLOYMENT_ENVIRONMENT", "prod")
BATCH = int(os.environ.get("BATCH_SIZE", "500"))
TIMEOUT = 10
MAX_RESPONSE_BYTES = 4 * 1024 * 1024  # OTLP 명세가 권하는 응답 크기 한도
RETRIES = 3
CHUNK = 1024 * 1024
LOADTEST_UA = "nova-loadtest/"  # CloudFront 로그는 User-Agent 를 URL 인코딩하지만 이 문자열에는 인코딩되는 글자가 없다

s3 = boto3.client("s3")


def handler(event, _context):
    sent = rejected = 0
    for record in event.get("Records", []):
        bucket = record["s3"]["bucket"]["name"]
        key = unquote_plus(record["s3"]["object"]["key"])
        source = source_of(key)
        if source is None:
            print(json.dumps({"skip": key}))
            continue
        data = s3.get_object(Bucket=bucket, Key=key)["Body"].read()
        gz = key.endswith(".gz")
        if gz:
            check_gzip(data)
        parse = parse_alb if source == "alb" else parse_cloudfront
        skipped = Skipped()
        count = dropped = 0
        batch = []
        for r in parse(lines_of(io.BytesIO(data), gz), skipped):
            batch.append(r)
            if len(batch) >= BATCH:
                dropped += post(source, batch)
                count += len(batch)
                batch = []
        if batch:
            dropped += post(source, batch)
            count += len(batch)
        sent += count - dropped
        rejected += dropped
        print(json.dumps({"key": key, "source": source, "records": count, "rejected": dropped, "loadtest_skipped": skipped.loadtest}))
    return {"records": sent, "rejected": rejected}


class Skipped:
    """parse_* 가 버린 부하 시험 줄 수"""

    def __init__(self):
        self.loadtest = 0


def check_gzip(data):
    """끝까지 풀어 본다(CRC · 길이 검사). 깨진 파일이면 아무것도 보내기 전에 실패한다. 풀린 내용은 들지 않는다"""
    with gzip.GzipFile(fileobj=io.BytesIO(data)) as f:
        while f.read(CHUNK):
            pass


def lines_of(body, gz):
    """S3 객체를 CHUNK 씩 읽어 줄로 내놓는다. 메모리는 CHUNK 와 한 줄 크기로 묶인다"""
    stream = gzip.GzipFile(fileobj=body) if gz else body
    pending = b""
    while chunk := stream.read(CHUNK):
        pending += chunk
        *complete, pending = pending.split(b"\n")
        for raw in complete:
            yield raw.decode("utf-8", errors="replace").rstrip("\r")
    if pending:
        yield pending.decode("utf-8", errors="replace").rstrip("\r")


def source_of(key):
    if key.startswith("alb/"):
        return "alb"
    if key.startswith("cloudfront/"):
        return "cloudfront"
    return None


# ── ALB ─────────────────────────────────────────────────────
# https://docs.aws.amazon.com/elasticloadbalancing/latest/application/load-balancer-access-logs.html
ALB_TYPES = {"http", "https", "h2", "grpcs", "ws", "wss"}
ALB_FIELDS = [
    "type", "time", "elb", "client", "target", "request_processing_time", "target_processing_time",
    "response_processing_time", "elb_status_code", "target_status_code", "received_bytes", "sent_bytes",
    "request", "user_agent", "ssl_cipher", "ssl_protocol", "target_group_arn", "trace_id", "domain_name",
    "chosen_cert_arn", "matched_rule_priority", "request_creation_time", "actions_executed", "redirect_url",
    "error_reason", "target_list", "target_status_list", "classification", "classification_reason",
]


def parse_alb(lines, skipped=None):
    skipped = skipped or Skipped()
    for line in lines:
        if not line.strip():
            continue
        # User-Agent 는 요청 줄 다음의 따옴표 필드다. shlex 가 무거워서 그 전에 문자열로 거른다(URL 의 따옴표 · 공백은 인코딩되어 있다)
        if f' "{LOADTEST_UA}' in line:
            skipped.loadtest += 1
            continue
        try:
            values = shlex.split(line)
        except ValueError:
            continue
        f = dict(zip(ALB_FIELDS, values))
        # 요청 줄만 읽는다. 접근 로그를 켤 때 ALB 가 쓰는 시험 파일(ELBAccessLogTestFile) 같은 줄은 건너뛴다
        if f.get("type") not in ALB_TYPES:
            continue
        method, path, protocol = split_request(f.get("request", ""))
        status = to_int(f.get("elb_status_code"))
        attrs = {
            "http.request.method": method,
            "url.path": path,
            "network.protocol.name": protocol,
            "http.response.status_code": status,
            "aws.alb.target_status_code": to_int(f.get("target_status_code")),
            "aws.alb.request_processing_time": to_seconds(f.get("request_processing_time")),
            "aws.alb.target_processing_time": to_seconds(f.get("target_processing_time")),
            "aws.alb.response_processing_time": to_seconds(f.get("response_processing_time")),
            "aws.alb.target_group": target_group(f.get("target_group_arn", "")),
            "aws.alb.received_bytes": to_int(f.get("received_bytes")),
            "aws.alb.sent_bytes": to_int(f.get("sent_bytes")),
            "aws.alb.error_reason": dash_none(f.get("error_reason")),
            "aws.alb.classification": dash_none(f.get("classification")),
            "server.address": dash_none(f.get("domain_name")),
            # 앱 스팬의 http.request.header.x-amzn-trace-id 와 같은 값(Root=1-…)
            "aws.xray.trace_id": root_trace_id(f.get("trace_id", "")),
        }
        total = sum(v for v in (attrs["aws.alb.request_processing_time"], attrs["aws.alb.target_processing_time"],
                                attrs["aws.alb.response_processing_time"]) if v is not None)
        yield make_record(f.get("time", ""), status, f"{method} {path} {status} {total:.3f}s", attrs)


def split_request(request):
    parts = request.split(" ")
    if len(parts) < 2:
        return "-", "-", None
    method, url = parts[0], parts[1]
    protocol = parts[2] if len(parts) > 2 else None
    return method, urlsplit(url).path or "/", protocol


def target_group(arn):
    # arn:aws:elasticloadbalancing:<리전>:<계정>:targetgroup/<이름>/<id> → <이름>
    parts = arn.split("/")
    return parts[1] if len(parts) >= 3 else None


def root_trace_id(value):
    for part in value.split(";"):
        if part.startswith("Root="):
            return part
    return None


# ── CloudFront (표준 로그, 탭 구분) ──────────────────────────
# https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/standard-logs-reference.html
def parse_cloudfront(lines, skipped=None):
    skipped = skipped or Skipped()
    fields = None
    for line in lines:
        if line.startswith("#Fields:"):
            fields = line[len("#Fields:"):].split()
            continue
        if line.startswith("#") or not line.strip() or fields is None:
            continue
        f = dict(zip(fields, line.split("\t")))
        if f.get("cs(User-Agent)", "").startswith(LOADTEST_UA):
            skipped.loadtest += 1
            continue
        method = f.get("cs-method", "-")
        path = unquote(f.get("cs-uri-stem", "-"))
        status = to_int(f.get("sc-status"))
        taken = to_seconds(f.get("time-taken"))
        attrs = {
            "http.request.method": method,
            "url.path": path,
            "http.response.status_code": status,
            "network.protocol.version": dash_none(f.get("cs-protocol-version")),
            "server.address": dash_none(f.get("x-host-header")),
            "client.address": truncate_ip(f.get("c-ip")),
            "aws.cloudfront.edge_location": dash_none(f.get("x-edge-location")),
            "aws.cloudfront.result_type": dash_none(f.get("x-edge-result-type")),
            "aws.cloudfront.response_result_type": dash_none(f.get("x-edge-response-result-type")),
            "aws.cloudfront.detailed_result_type": dash_none(f.get("x-edge-detailed-result-type")),
            "aws.cloudfront.time_taken": taken,
            "aws.cloudfront.time_to_first_byte": to_seconds(f.get("time-to-first-byte")),
            "aws.cloudfront.sent_bytes": to_int(f.get("sc-bytes")),
            "aws.cloudfront.content_type": dash_none(unquote(f.get("sc-content-type", "-"))),
            # 앱 스팬의 http.request.header.x-amz-cf-id 와 같은 값
            "aws.cloudfront.request_id": dash_none(f.get("x-edge-request-id")),
        }
        when = f"{f.get('date', '')}T{f.get('time', '')}Z"
        yield make_record(when, status, f"{method} {path} {status} {taken or 0:.3f}s {attrs['aws.cloudfront.result_type']}", attrs)


def truncate_ip(value):
    try:
        ip = ipaddress.ip_address(value)
    except (TypeError, ValueError):
        return None
    prefix = 24 if ip.version == 4 else 48
    return str(ipaddress.ip_network(f"{ip}/{prefix}", strict=False))


# ── OTLP ────────────────────────────────────────────────────
def make_record(when, status, body, attrs):
    severity = ("ERROR", 17) if status and status >= 500 else ("WARN", 13) if status and status >= 400 else ("INFO", 9)
    return {
        "timeUnixNano": str(to_nanos(when)),
        "observedTimeUnixNano": str(time.time_ns()),
        "severityText": severity[0],
        "severityNumber": severity[1],
        "body": {"stringValue": body},
        "attributes": [attribute(k, v) for k, v in attrs.items() if v is not None],
    }


def attribute(key, value):
    if isinstance(value, bool):
        return {"key": key, "value": {"boolValue": value}}
    if isinstance(value, int):
        return {"key": key, "value": {"intValue": str(value)}}
    if isinstance(value, float):
        return {"key": key, "value": {"doubleValue": value}}
    return {"key": key, "value": {"stringValue": str(value)}}


def post(source, records):
    """records 를 보내고 받는 쪽이 거절한 레코드 수를 돌려준다."""
    payload = {
        "resourceLogs": [{
            "resource": {"attributes": [
                attribute("service.name", source),
                attribute("service.namespace", "edge"),
                attribute("deployment.environment", ENVIRONMENT),
            ]},
            "scopeLogs": [{"scope": {"name": "nova.edgelogs"}, "logRecords": records}],
        }]
    }
    data = json.dumps(payload, separators=(",", ":")).encode()
    for attempt in range(RETRIES):
        request = urllib.request.Request(ENDPOINT, data=data, headers={"Content-Type": "application/json"}, method="POST")
        try:
            with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
                body = response.read(MAX_RESPONSE_BYTES + 1)
            if len(body) > MAX_RESPONSE_BYTES:
                raise RuntimeError("OTLP response is larger than 4 MiB")
            return rejected_count(body)
        except urllib.error.HTTPError as e:
            # 4xx(429 제외)는 다시 보내도 같다
            if e.code < 500 and e.code != 429:
                raise
            error = e
        except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
            error = e
        time.sleep(2 ** attempt)
    raise RuntimeError(f"OTLP export failed after {RETRIES} attempts: {error}")


def rejected_count(body):
    # 200 이어도 일부를 거절할 수 있다(OTLP partialSuccess). 다 받으면 게이트웨이는 {"partialSuccess":{}} 를 돌려준다.
    # 본문이 비었거나 형식이 다르면 받았는지 알 수 없으므로 실패로 본다
    try:
        partial = json.loads(body).get("partialSuccess") or {}
        count = int(partial.get("rejectedLogRecords") or 0)
    except (ValueError, TypeError, AttributeError) as e:
        raise RuntimeError(f"invalid OTLP response: {body[:200]!r}") from e
    if count:
        print(json.dumps({"rejected": count, "message": partial.get("errorMessage", "")}))
    return count


# ── 값 변환 ────────────────────────────────────────────────
EPOCH = datetime(1970, 1, 1, tzinfo=timezone.utc)


def to_nanos(value):
    # float 로 곱하면 마이크로초 아래가 어긋난다. 정수로만 계산한다
    try:
        delta = datetime.fromisoformat(value.replace("Z", "+00:00")) - EPOCH
    except (TypeError, ValueError):
        return time.time_ns()
    return (delta.days * 86400 + delta.seconds) * 1_000_000_000 + delta.microseconds * 1000


def to_int(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def to_seconds(value):
    # ALB 는 대상에 닿지 못하면 -1 을 쓴다
    try:
        v = float(value)
    except (TypeError, ValueError):
        return None
    return None if v < 0 else v


def dash_none(value):
    return None if value in (None, "", "-") else value
