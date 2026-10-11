# ─────────────────────────────────────────────────────────────
# bastion — DB 접속용 경유 인스턴스
#
# SSH 포트를 열지 않고 Session Manager 포트포워딩으로 접속한다.
# 키페어를 만들지 않으므로 유출될 키도 없다.
#
#   aws ssm start-session \
#     --target <instance-id> \
#     --document-name AWS-StartPortForwardingSessionToRemoteHost \
#     --parameters '{"host":["<db-endpoint>"],"portNumber":["3306"],"localPortNumber":["13306"]}'
# ─────────────────────────────────────────────────────────────

# 최신 Amazon Linux 2023(ARM) AMI 를 SSM 파라미터에서 가져온다.
# AMI ID 를 하드코딩하면 리전이나 시점에 따라 깨진다.
data "aws_ssm_parameter" "al2023_arm64" {
  count = var.ami_id == "" ? 1 : 0

  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

locals {
  ami_id = var.ami_id != "" ? var.ami_id : data.aws_ssm_parameter.al2023_arm64[0].value
}

resource "aws_instance" "this" {
  count = var.enabled ? 1 : 0

  ami           = local.ami_id
  instance_type = var.instance_type

  # 앱 서브넷에 둔다. 공인 IP 가 없어도 SSM 은 아웃바운드로 연결된다.
  subnet_id              = data.terraform_remote_state.vpc.outputs.app_subnet_ids[0]
  vpc_security_group_ids = [data.terraform_remote_state.security.outputs.bastion_security_group_id]
  iam_instance_profile   = data.terraform_remote_state.iam.outputs.bastion_instance_profile

  associate_public_ip_address = false

  metadata_options {
    http_tokens                 = "required" # IMDSv2 강제
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = <<-EOT
    #!/bin/bash
    dnf install -y mariadb105
  EOT

  tags = { Name = "${local.name_prefix}-bastion" }

  lifecycle {
    # 최신 AMI 가 나올 때마다 인스턴스가 교체되지 않게 한다. 갱신은 -replace 로 한다
    ignore_changes = [ami]
  }
}
