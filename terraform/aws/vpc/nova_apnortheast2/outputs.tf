output "vpc_id" {
  value = aws_vpc.this.id
}

output "vpc_cidr" {
  value = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "app_subnet_ids" {
  value = aws_subnet.app[*].id
}

output "db_subnet_ids" {
  value = aws_subnet.db[*].id
}

output "app_route_table_ids" {
  value = aws_route_table.app[*].id
}

output "vpce_security_group_id" {
  value = aws_security_group.vpce.id
}

output "nat_public_ips" {
  description = "외부 시스템 IP 허용목록 등록에 쓴다"
  value       = aws_eip.nat[*].public_ip
}
