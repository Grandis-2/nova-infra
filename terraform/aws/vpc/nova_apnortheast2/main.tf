# 3-tier VPC. AZ 2개에 public/app/db 서브넷을 하나씩 둔다.
#   public : ALB, NAT 만 둔다
#   app    : ECS 태스크. 아웃바운드는 같은 AZ 의 NAT 로 나간다
#   db     : ElastiCache. 기본 경로(0.0.0.0/0)가 없다

locals {
  azs = var.availability_zones

  # 운영은 AZ 마다 NAT 하나, 비용을 줄일 때는 하나만 둔다
  nat_count = var.single_nat_gateway ? 1 : length(local.azs)
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true # Interface Endpoint 의 Private DNS 에 필요

  tags = { Name = "${local.name_prefix}-vpc" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = { Name = "${local.name_prefix}-igw" }
}

# ── 서브넷 ───────────────────────────────────────────────────
resource "aws_subnet" "public" {
  count = length(local.azs)

  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false # ALB, NAT 는 자체 공인 IP 를 쓴다

  tags = {
    Name = "${local.name_prefix}-public-${local.az_suffix[count.index]}"
    Tier = "public"
  }
}

resource "aws_subnet" "app" {
  count = length(local.azs)

  vpc_id            = aws_vpc.this.id
  cidr_block        = var.app_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = {
    Name = "${local.name_prefix}-app-${local.az_suffix[count.index]}"
    Tier = "app"
  }
}

resource "aws_subnet" "db" {
  count = length(local.azs)

  vpc_id            = aws_vpc.this.id
  cidr_block        = var.db_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = {
    Name = "${local.name_prefix}-db-${local.az_suffix[count.index]}"
    Tier = "db"
  }
}

# ── NAT ──────────────────────────────────────────────────────
# AZ 마다 두면 한 AZ 장애가 다른 AZ 아웃바운드에 번지지 않고, AZ 간 전송 요금도 없다.
#
# nat_mode
#   instance : fck-nat EC2. 트래픽이 적을 때 게이트웨이보다 훨씬 싸다.
#              AZ 마다 ASG(1대)로 띄우고, 교체되면 EIP 와 ENI 를 다시 붙인다.
#              교체되는 몇 분 동안 그 AZ 의 아웃바운드가 끊긴다.
#   gateway  : 관리형 NAT 게이트웨이. 트래픽이 커지면 이쪽으로 바꾼다.
#
# 두 모드 모두 같은 aws_eip 를 쓴다. NCP DB ACG 가 이 IP 를 허용하므로 모드를 바꿔도 접속이 유지된다.
# DB 트래픽이 모두 NAT 를 지나므로 NAT 인스턴스 크기와 상태를 주시해야 한다.
resource "aws_eip" "nat" {
  count = local.nat_count

  domain = "vpc"

  tags = { Name = "${local.name_prefix}-nat-eip-${local.az_suffix[count.index]}" }
}

resource "aws_nat_gateway" "this" {
  count = var.nat_mode == "gateway" ? local.nat_count : 0

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = { Name = "${local.name_prefix}-nat-${local.az_suffix[count.index]}" }

  depends_on = [aws_internet_gateway.this]
}

module "nat_instance" {
  source = "git::https://github.com/RaJiska/terraform-aws-fck-nat.git?ref=v1.6.1"
  count  = var.nat_mode == "instance" ? local.nat_count : 0

  # IAM 역할, 인스턴스 프로파일 이름으로도 쓴다. Terraform 역할은 <product>-* 이름만 만들 수 있다
  name          = "${local.name_prefix}-nat-${local.az_suffix[count.index]}"
  vpc_id        = aws_vpc.this.id
  subnet_id     = aws_subnet.public[count.index].id
  instance_type = var.nat_instance_type

  ha_mode            = true # ASG 1대. 교체되면 ENI, EIP 를 다시 붙인다
  eip_allocation_ids = [aws_eip.nat[count.index].id]

  # 이 NAT 를 쓰는 app 라우팅 테이블에 0.0.0.0/0 → NAT ENI 경로를 넣는다
  update_route_tables = true
  route_tables_ids = var.single_nat_gateway ? {
    for i, rt in aws_route_table.app : "app-${local.az_suffix[i]}" => rt.id
    } : {
    "app-${local.az_suffix[count.index]}" = aws_route_table.app[count.index].id
  }

  tags = { Name = "${local.name_prefix}-nat-${local.az_suffix[count.index]}" }

  depends_on = [aws_internet_gateway.this]
}

# ── 라우팅 ───────────────────────────────────────────────────
# public 은 경로가 같아 두 AZ 가 하나를 같이 쓴다
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = { Name = "${local.name_prefix}-public-rt" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count = length(local.azs)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# app 은 같은 AZ 의 NAT 를 가리켜야 하므로 AZ 마다 따로 둔다
resource "aws_route_table" "app" {
  count = length(local.azs)

  vpc_id = aws_vpc.this.id

  tags = { Name = "${local.name_prefix}-app-rt-${local.az_suffix[count.index]}" }
}

resource "aws_route" "app_nat" {
  count = var.nat_mode == "gateway" ? length(local.azs) : 0

  route_table_id         = aws_route_table.app[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[var.single_nat_gateway ? 0 : count.index].id
}

resource "aws_route_table_association" "app" {
  count = length(local.azs)

  subnet_id      = aws_subnet.app[count.index].id
  route_table_id = aws_route_table.app[count.index].id
}

# db 는 기본 경로가 없어 인터넷으로 나갈 수 없다
resource "aws_route_table" "db" {
  vpc_id = aws_vpc.this.id

  tags = { Name = "${local.name_prefix}-db-rt" }
}

resource "aws_route_table_association" "db" {
  count = length(local.azs)

  subnet_id      = aws_subnet.db[count.index].id
  route_table_id = aws_route_table.db.id
}

# ── VPC 엔드포인트 ───────────────────────────────────────────
# S3 Gateway 엔드포인트는 무료라 항상 만든다
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = concat(
    aws_route_table.app[*].id,
    [aws_route_table.db.id],
  )

  tags = { Name = "${local.name_prefix}-vpce-s3" }
}

# Interface Endpoint 용 SG. 앱 SG 를 참조하는 인바운드 규칙은
# 순환 참조를 피하려고 securitygroup 스택에서 붙인다.
resource "aws_security_group" "vpce" {
  name        = "${local.name_prefix}-vpce-sg"
  description = "Interface VPC endpoint ENI"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${local.name_prefix}-vpce-sg" }
}

resource "aws_vpc_endpoint" "interface" {
  for_each = var.enable_interface_endpoints ? toset(var.interface_endpoint_services) : toset([])

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.aws_region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.app[*].id
  security_group_ids  = [aws_security_group.vpce.id]
  private_dns_enabled = true # SDK 가 기본 엔드포인트 주소로 그대로 접근하게 한다

  tags = { Name = "${local.name_prefix}-vpce-${replace(each.value, ".", "-")}" }
}

# ── Flow Logs (선택) ─────────────────────────────────────────
resource "aws_cloudwatch_log_group" "flow" {
  count = var.enable_flow_logs ? 1 : 0

  name              = "/aws/vpc/${local.name_prefix}"
  retention_in_days = var.flow_log_retention_days
}

data "aws_iam_policy_document" "flow_assume" {
  count = var.enable_flow_logs ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "flow" {
  count = var.enable_flow_logs ? 1 : 0

  name               = "${local.name_prefix}-vpc-flow-log"
  assume_role_policy = data.aws_iam_policy_document.flow_assume[0].json
}

resource "aws_iam_role_policy" "flow" {
  count = var.enable_flow_logs ? 1 : 0

  name = "write-logs"
  role = aws_iam_role.flow[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    # 액션마다 권한을 확인하는 리소스가 다르다 — 스트림 생성 · 조회는 로그 그룹, 기록은 로그 스트림
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:DescribeLogStreams"]
        Resource = [aws_cloudwatch_log_group.flow[0].arn, "${aws_cloudwatch_log_group.flow[0].arn}:*"]
      },
      {
        Effect   = "Allow"
        Action   = ["logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.flow[0].arn}:log-stream:*"
      },
    ]
  })
}

resource "aws_flow_log" "this" {
  count = var.enable_flow_logs ? 1 : 0

  vpc_id               = aws_vpc.this.id
  traffic_type         = "REJECT" # 비용을 줄이려고 차단된 트래픽만 남긴다
  iam_role_arn         = aws_iam_role.flow[0].arn
  log_destination      = aws_cloudwatch_log_group.flow[0].arn
  log_destination_type = "cloud-watch-logs"

  tags = { Name = "${local.name_prefix}-flow-log" }
}
