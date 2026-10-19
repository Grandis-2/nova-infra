# 부하 시험(Grandis-2/nova-loadtest) 인프라. 새로 만드는 시험 리소스를 이 스택 하나에 모은다.
# 저장소의 다른 스택은 리소스 종류별(ecr, s3, iam, ecs …)이지만, 시험 리소스를 운영 리소스와 섞지 않고
# 한 번에 적용하고 한 번에 걷어내려고 이 스택만 예외로 묶는다. 파일은 종류별로 나눈다.
#
#   ecr.tf            이미지 저장소 셋 (k6 · 컨트롤러 · 토큰 발급기). nova-loadtest main 만 올린다
#   s3.tf             토큰(tokens/) · 결과(results/) 버킷
#   securitygroup.tf  시험 태스크 SG 셋과, 게이트웨이 · obs · 엔드포인트 SG 에 더하는 들어오는 규칙
#   iam.tf            GitHub 역할 둘, 태스크 역할 셋, 실행 역할 둘
#   ecs.tf            클러스터 · 작업 정의 셋 · 로그 그룹
#   ssm.tf            nova-loadtest 워크플로가 읽는 실행 파라미터 둘
#
# 기존 리소스를 고치는 것은 원래 스택에 있다: 헤더 비밀(secretsmanager), 게이트웨이 k6 지표 허용 목록(lgtm),
# WAF 요청 제한 예외(edge), 엣지 로그 거르기(lambda).
# 흐름: GitHub Actions → 컨트롤러 태스크 → 발급기 · k6 N 대. k6 → API(공인 IP), k6 지표 → 게이트웨이 → Mimir, 컨트롤러 → Mimir 조회

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  loadtest_name = "${local.name_prefix}-loadtest"
  account_id    = data.aws_caller_identity.current.account_id
  partition     = data.aws_partition.current.partition

  vpc_id         = data.terraform_remote_state.vpc.outputs.vpc_id
  public_subnets = data.terraform_remote_state.vpc.outputs.public_subnet_ids
  app_subnets    = data.terraform_remote_state.vpc.outputs.app_subnet_ids

  # 스택 경로(…/terraform/aws/…)를 기준으로 terraform/application 을 찾는다 (다른 스택의 locals_services.tf 와 같은 방식)
  application_dir = "${regex("^(.*)/terraform/aws/", "${abspath(path.root)}/")[0]}/terraform/application"
}
