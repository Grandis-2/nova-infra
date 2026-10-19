"""파서 단위 시험. 실행: python -m unittest discover -s functions/edge-logs/tests

로그 줄은 형식만 실제와 같고 값은 지어낸 것이다.
"""

import gzip
import importlib.util
import io
import os
import sys
import types
import unittest
from pathlib import Path

# 런타임에만 있는 boto3 와 환경 변수를 대신한다
sys.modules.setdefault("boto3", types.SimpleNamespace(client=lambda *_: None))
os.environ.setdefault("OTLP_ENDPOINT", "http://localhost:4318")
_spec = importlib.util.spec_from_file_location("handler", Path(__file__).resolve().parent.parent / "handler.py")
handler = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(handler)

ALB_LINE = (
    'https 2026-10-16T00:47:56.968592Z app/nova-prod-alb/0123456789abcdef 192.0.2.10:57926 10.0.11.178:8080 '
    '0.001 0.004 0.000 503 503 2320 844 "GET https://origin.example.com:443/api/v1/items/42?email=a@b.c HTTP/1.1" '
    '"Mozilla/5.0" TLS_AES_128_GCM_SHA256 TLSv1.3 '
    'arn:aws:elasticloadbalancing:ap-northeast-2:111111111111:targetgroup/nova-prod-member-0-green/0123456789abcdef '
    '"Root=1-6ad1743c-19de76831e1073c2130372ed;Self=1-6ad1743c-000000000000000000000000" "origin.example.com" "session-reused" 90 '
    '2026-10-16T00:47:56.963000Z "forward" "-" "-" "10.0.11.178:8080" "503" "-" "-" TID_0123 "-" "-" "-"'
)
ALB_UNREACHED = (
    'https 2026-10-16T00:48:00.000000Z app/nova-prod-alb/0123456789abcdef 192.0.2.10:1 - '
    '-1 -1 -1 502 - 100 200 "POST https://origin.example.com:443/api/v1/orders HTTP/2.0" "-" - - '
    'arn:aws:elasticloadbalancing:ap-northeast-2:111111111111:targetgroup/nova-prod-order-0-blue/0123456789abcdef '
    '"Root=1-6ad1743c-29de76831e1073c2130372ed" "origin.example.com" "-" 0 2026-10-16T00:48:00.000000Z "forward" "-" '
    '"TargetConnectionError" "-" "-" "-" "-"'
)
CF_LINES = [
    "#Version: 1.0",
    "#Fields: date time x-edge-location sc-bytes c-ip cs-method cs(Host) cs-uri-stem sc-status cs(Referer) "
    "cs(User-Agent) cs-uri-query cs(Cookie) x-edge-result-type x-edge-request-id x-host-header cs-protocol cs-bytes "
    "time-taken x-forwarded-for ssl-protocol ssl-cipher x-edge-response-result-type cs-protocol-version fle-status "
    "fle-encrypted-fields c-port time-to-first-byte x-edge-detailed-result-type sc-content-type sc-content-len "
    "sc-range-start sc-range-end",
    "\t".join([
        "2026-10-16", "00:40:18", "ICN53-P1", "1217", "198.51.100.77", "GET", "d111111abcdef8.cloudfront.net",
        "/api/v1/%ED%95%9C%EA%B8%80", "200", "-", "Mozilla/5.0%20(X11)", "token=secret", "session=x", "Miss",
        "REQUESTID0123456789abcdefghij==", "api.example.com", "https", "300", "0.120", "-", "TLSv1.3",
        "TLS_AES_128_GCM_SHA256", "Miss", "HTTP/2.0", "-", "-", "52000", "0.118", "Miss",
        "application/json;%20charset=utf-8", "100", "-", "-",
    ]),
    "\t".join(["2026-10-16", "00:41:00", "ICN53-P1", "0", "2001:db8:abcd:12::1", "GET", "d111111abcdef8.cloudfront.net",
               "/", "504", "-", "-", "-", "-", "Error", "REQ2", "api.example.com", "https", "0", "30.001", "-", "-",
               "-", "Error", "HTTP/1.1", "-", "-", "1", "-", "OriginCommError", "-", "-", "-", "-"]),
]


LOADTEST_ALB = ALB_LINE.replace('"Mozilla/5.0"', '"nova-loadtest/lt-20261019t0630-1"')
LOADTEST_CF = CF_LINES[2].replace("Mozilla/5.0%20(X11)", "nova-loadtest/lt-20261019t0630-1")


def attrs(record):
    return {a["key"]: next(iter(a["value"].values())) for a in record["attributes"]}


class AlbTest(unittest.TestCase):
    def test_request_fields(self):
        [r] = list(handler.parse_alb([ALB_LINE]))
        a = attrs(r)
        self.assertEqual(a["http.request.method"], "GET")
        self.assertEqual(a["url.path"], "/api/v1/items/42")  # 쿼리 문자열은 버린다
        self.assertEqual(a["http.response.status_code"], "503")
        self.assertEqual(a["aws.alb.target_group"], "nova-prod-member-0-green")
        self.assertEqual(a["aws.xray.trace_id"], "Root=1-6ad1743c-19de76831e1073c2130372ed")  # Self 는 버린다
        self.assertEqual(r["severityText"], "ERROR")
        self.assertNotIn("client.address", a)  # ALB 의 클라이언트는 CloudFront 엣지다
        self.assertNotIn("email=", r["body"]["stringValue"])

    def test_target_not_reached(self):
        [r] = list(handler.parse_alb([ALB_UNREACHED]))
        a = attrs(r)
        self.assertNotIn("aws.alb.target_processing_time", a)  # -1 은 값이 없는 것이다
        self.assertEqual(a["aws.alb.error_reason"], "TargetConnectionError")
        self.assertNotIn("aws.alb.target_status_code", a)

    def test_skips_non_request_lines(self):
        self.assertEqual(list(handler.parse_alb(["Enable AccessLog for ELB: nova-prod-alb at 2026-10-16T00:00:00Z", ""])), [])


class CloudFrontTest(unittest.TestCase):
    def test_request_fields(self):
        r, r6 = list(handler.parse_cloudfront(CF_LINES))
        a = attrs(r)
        self.assertEqual(a["url.path"], "/api/v1/한글")
        self.assertEqual(a["client.address"], "198.51.100.0/24")
        self.assertEqual(a["aws.cloudfront.request_id"], "REQUESTID0123456789abcdefghij==")
        self.assertEqual(a["aws.cloudfront.content_type"], "application/json; charset=utf-8")
        self.assertEqual(a["aws.cloudfront.time_taken"], 0.12)
        for value in a.values():
            self.assertNotIn("secret", str(value))  # 쿼리 문자열 · 쿠키는 남기지 않는다
        self.assertEqual(attrs(r6)["client.address"], "2001:db8:abcd::/48")
        self.assertEqual(r6["severityText"], "ERROR")

    def test_needs_fields_header(self):
        self.assertEqual(list(handler.parse_cloudfront(CF_LINES[2:])), [])


class OtlpTest(unittest.TestCase):
    def test_timestamp_and_types(self):
        [r] = list(handler.parse_alb([ALB_LINE]))
        self.assertEqual(r["timeUnixNano"], "1792111676968592000")
        values = {a["key"]: a["value"] for a in r["attributes"]}
        self.assertIn("intValue", values["http.response.status_code"])
        self.assertIn("doubleValue", values["aws.alb.target_processing_time"])

    def test_source_of(self):
        self.assertEqual(handler.source_of("alb/AWSLogs/x.log.gz"), "alb")
        self.assertEqual(handler.source_of("cloudfront/E1.2026-10-16-00.x.gz"), "cloudfront")
        self.assertIsNone(handler.source_of("cloudfront-grafana/E2.x.gz"))

    def test_partial_success(self):
        self.assertEqual(handler.rejected_count(b'{"partialSuccess":{}}'), 0)  # 게이트웨이가 다 받았을 때
        self.assertEqual(handler.rejected_count(b"{}"), 0)
        self.assertEqual(handler.rejected_count(b'{"partialSuccess":{"rejectedLogRecords":"3","errorMessage":"x"}}'), 3)

    def test_invalid_response_is_failure(self):
        for body in (b"", b"not json", b"[]", b"null"):
            with self.assertRaises(RuntimeError):
                handler.rejected_count(body)


class LoadtestFilterTest(unittest.TestCase):
    def test_alb_skips_loadtest_user_agent(self):
        skipped = handler.Skipped()
        records = list(handler.parse_alb([LOADTEST_ALB, ALB_LINE], skipped))
        self.assertEqual(len(records), 1)
        self.assertEqual(skipped.loadtest, 1)

    def test_cloudfront_skips_loadtest_user_agent(self):
        skipped = handler.Skipped()
        records = list(handler.parse_cloudfront(CF_LINES[:2] + [LOADTEST_CF, CF_LINES[2]], skipped))
        self.assertEqual(len(records), 1)
        self.assertEqual(skipped.loadtest, 1)

    def test_path_with_loadtest_text_is_kept(self):
        # 경로에 같은 글자가 있어도 User-Agent 가 아니면 남긴다
        line = ALB_LINE.replace("/api/v1/items/42", "/api/v1/nova-loadtest/42")
        self.assertEqual(len(list(handler.parse_alb([line]))), 1)


class StreamTest(unittest.TestCase):
    """큰 파일을 통째로 들지 않고 줄 단위로 읽어 BATCH 씩 보내는지"""

    def setUp(self):
        self.batches = []
        self._post, self._s3, self._chunk = handler.post, handler.s3, handler.CHUNK
        handler.post = lambda source, records: self.batches.append(len(records)) or 0
        handler.CHUNK = 4096  # 줄이 청크 경계에 걸치는 경우를 만든다

    def tearDown(self):
        handler.post, handler.s3, handler.CHUNK = self._post, self._s3, self._chunk

    def run_file(self, key, lines, gz=True):
        data = "\n".join(lines).encode()
        body = io.BytesIO(gzip.compress(data) if gz else data)
        handler.s3 = types.SimpleNamespace(get_object=lambda **_: {"Body": body})
        event = {"Records": [{"s3": {"bucket": {"name": "b"}, "object": {"key": key}}}]}
        return handler.handler(event, None)

    def test_large_alb_file(self):
        lines = [LOADTEST_ALB] * 3000 + [ALB_LINE] * 1200
        result = self.run_file("alb/AWSLogs/x.log.gz", lines)
        self.assertEqual(result, {"records": 1200, "rejected": 0})
        self.assertEqual(self.batches, [500, 500, 200])

    def test_cloudfront_plain_file(self):
        lines = CF_LINES[:2] + [LOADTEST_CF] * 10 + [CF_LINES[2]] * 3
        result = self.run_file("cloudfront/E1.2026-10-19-00.x", lines, gz=False)
        self.assertEqual(result["records"], 3)

    def test_lines_split_across_chunks(self):
        body = io.BytesIO(gzip.compress(("x" * 5000 + "\n" + "y" * 10 + "\r\n" + "z").encode()))
        self.assertEqual([len(l) for l in handler.lines_of(body, True)], [5000, 10, 1])


if __name__ == "__main__":
    unittest.main()
