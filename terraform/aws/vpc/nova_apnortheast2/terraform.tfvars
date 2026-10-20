vpc_cidr = "10.0.0.0/16"

# AZ 순서: [2a, 2c]
public_subnet_cidrs = ["10.0.0.0/24", "10.0.1.0/24"]   # ALB · NAT 전용
app_subnet_cidrs    = ["10.0.10.0/24", "10.0.11.0/24"] # ECS 태스크 ENI
db_subnet_cidrs     = ["10.0.20.0/24", "10.0.21.0/24"] # ElastiCache · RDS

# NAT 인스턴스를 AZ 마다 하나 둔다. 트래픽이 커지면 nat_mode = "gateway".
nat_mode           = "instance"
single_nat_gateway = false

# db 서브넷은 NAT 로 나가지 않는다(RDS 이전의 NCP → RDS 복제 기간에만 true 였다)
db_subnet_nat_egress = false

# NAT 로 충분하므로 끈다. 비용보다 트래픽 격리가 중요해지면 켠다.
enable_interface_endpoints = false

enable_flow_logs = false
