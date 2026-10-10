# NAVER Cloud Platform provider (ncp/* 스택에 심볼릭 링크)
#
# API 키는 코드에 두지 않는다. provider 가 NCLOUD_ACCESS_KEY, NCLOUD_SECRET_KEY 환경변수를 읽는다.
# ncp/* 스택은 aws/provider.tf 도 함께 쓴다. DB 접속 정보를 Secrets Manager 에 넣고
# VPC 상태에서 NAT 고정 IP 를 읽어야 하기 때문이다.
provider "ncloud" {
  region      = "KR"
  site        = "public"
  support_vpc = true # NCP 는 VPC 환경만 지원한다
}
