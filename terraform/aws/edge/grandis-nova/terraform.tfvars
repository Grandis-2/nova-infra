# API 전용 하위 도메인 (www 와 apex 는 Vercel 이 쓴다). Route 53 호스팅 영역이 있어야 한다.
# 비우면 CloudFront 기본 주소와 HTTP 원본으로 뜬다.
domain_name       = "api.grandis-nova.link"
route53_zone_name = "grandis-nova.link"
