# CloudFront → ALB 를 HTTPS 로 받는다 (edge 가 origin.<도메인> 으로 붙는다).
# edge 의 domain_name 을 비우면 false 로 바꾼다. edge 설정과 다르면 edge plan 이 실패한다.
alb_origin_https = true
