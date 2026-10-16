# API 전용 하위 도메인. 프런트(www, apex)는 Vercel 이 쓴다.
# 비우면 인증서 없이 CloudFront 기본 주소와 HTTP 오리진을 쓴다.
domain_name       = "api.grandis-nova.link"
route53_zone_name = "grandis-nova.link"
# 이미지 CDN(cdn 스택)도 같은 CloudFront 인증서를 쓴다
subject_alternative_names = ["cdn.grandis-nova.link"]
# Grafana 공개 주소. Cognito 로그인을 거친다(NV-517)
grafana_domain_name = "grafana.grandis-nova.link"
# 브라우저 실사용자 모니터링(Faro) 수집 주소. 프런트가 바로 보낸다
rum_domain_name = "rum.grandis-nova.link"
# Atlantis 주소. 메인 ALB 로 받는다(atlantis-deploy 의 전용 ALB 를 없앤다)
atlantis_domain_name = "atlantis.grandis-nova.link"
