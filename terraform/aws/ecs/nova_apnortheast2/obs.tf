# ─────────────────────────────────────────────────────────────
# obs 용량 공급자 — 관측 스택(monitoring 스택의 obs 서비스, NV-425)을 올리는 EC2 1대
#
# 다른 서비스는 Fargate 다. obs 만 EC2 에 두는 이유는 Loki · Tempo · Mimir 의 WAL · TSDB 와 Grafana DB 가
# 재시작에도 남는 디스크에 있어야 하기 때문이다. Fargate 디스크는 태스크와 함께 사라진다.
#
#   데이터 EBS   : 인스턴스와 따로 산다. 부팅 스크립트가 붙이고 마운트한 뒤 클러스터에 들어간다
#   ASG          : 1대. 인스턴스가 죽으면 새로 띄우고, 같은 볼륨을 다시 붙인다 (같은 AZ 의 서브넷 하나에 묶는다)
#   용량 공급자  : 클러스터 기본 전략은 FARGATE 그대로다. obs 서비스만 이 공급자를 지정한다
#   IMDS        : 태스크(awsvpc)에서는 막는다 (ECS_AWSVPC_BLOCK_IMDS). 인스턴스 역할 권한이 컨테이너에 닿지 않는다
# ─────────────────────────────────────────────────────────────

# ECS 최적화 AL2023(ARM) AMI. 하드코딩하면 리전 · 시점에 따라 깨진다
data "aws_ssm_parameter" "ecs_al2023_arm64" {
  count = var.obs_ami_id == "" ? 1 : 0

  name = "/aws/service/ecs/optimized-ami/amazon-linux-2023/arm64/recommended/image_id"
}

# 데이터 볼륨과 인스턴스는 같은 AZ 여야 한다. 앱 서브넷 첫 번째 하나에 묶는다
data "aws_subnet" "obs" {
  id = local.app_subnets[0]
}

locals {
  obs_name       = "${local.name_prefix}-obs"
  obs_ami_id     = var.obs_ami_id != "" ? var.obs_ami_id : nonsensitive(data.aws_ssm_parameter.ecs_al2023_arm64[0].value)
  obs_mount_path = "/data/obs"

  # 데이터 디렉터리 -> 소유자 (uid:gid). monitoring 스택 obs.tf 의 컨테이너 user 와 같아야 한다
  obs_data_dirs = {
    loki      = "10001:10001"
    tempo     = "10001:10001"
    mimir     = "10001:10001"
    grafana   = "472:472"
    pyroscope = "10001:10001" # 프로파일(NV-540). v2 메타스토어(raft)가 디스크에 남아야 한다
  }
}

#trivy:ignore:AVD-AWS-0027
resource "aws_ebs_volume" "obs_data" {
  #checkov:skip=CKV_AWS_189:AWS 관리 키(aws/ebs)로 암호화된다. 고객 관리 KMS 키는 비용 · 키 관리만 늘린다
  #checkov:skip=CKV2_AWS_9:스냅샷 · 백업을 두지 않는다. 잃는 것은 S3 로 아직 올라가지 않은 최근 데이터와 Grafana 에서 손으로 만든 것뿐이다
  availability_zone = data.aws_subnet.obs.availability_zone
  size              = var.obs_data_volume_size
  type              = "gp3"
  encrypted         = true

  # iam 스택의 obs 인스턴스 역할은 이 Name 태그가 붙은 볼륨만 붙일 수 있다
  tags = { Name = "${local.obs_name}-data" }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_launch_template" "obs" {
  name                   = local.obs_name
  image_id               = local.obs_ami_id
  instance_type          = var.obs_instance_type
  update_default_version = true

  iam_instance_profile {
    name = data.terraform_remote_state.iam.outputs.obs_instance_profile
  }

  vpc_security_group_ids = [data.terraform_remote_state.security.outputs.obs_instance_security_group_id]

  metadata_options {
    http_tokens                 = "required" # IMDSv2 강제
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = 30
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  # 1분 지표. monitoring 의 CPU 크레딧 경보가 ASG 차원으로 본다
  monitoring {
    enabled = true
  }

  # t4g 는 버스트형이다. unlimited 면 크레딧이 바닥나도 느려지지 않고 초과분이 과금된다(monitoring 의 크레딧 경보로 본다)
  credit_specification {
    cpu_credits = "unlimited"
  }

  user_data = base64encode(templatefile("${path.module}/templates/obs_user_data.sh.tftpl", {
    region       = var.aws_region
    volume_id    = aws_ebs_volume.obs_data.id
    mount_path   = local.obs_mount_path
    cluster_name = aws_ecs_cluster.this.name
    data_dirs    = local.obs_data_dirs
  }))

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = local.obs_name }
  }

  tag_specifications {
    resource_type = "volume"
    tags          = { Name = "${local.obs_name}-root" }
  }

  lifecycle {
    # 최신 AMI 가 나올 때마다 새 버전 → 인스턴스 교체가 일어나지 않게 한다. 갱신은 obs_ami_id 를 넣거나 -replace 로 한다
    ignore_changes = [image_id]
  }
}

resource "aws_autoscaling_group" "obs" {
  name                = local.obs_name
  min_size            = 1
  max_size            = 1
  desired_capacity    = 1
  vpc_zone_identifier = [data.aws_subnet.obs.id]
  health_check_type   = "EC2"

  launch_template {
    id      = aws_launch_template.obs.id
    version = aws_launch_template.obs.latest_version
  }

  # 시작 템플릿(AMI · user_data)이 바뀌면 인스턴스를 바꾼다. 1대뿐이라 바꾸는 동안 obs 가 잠깐 빈다 (데이터는 EBS 에 남는다)
  instance_refresh {
    strategy = "Rolling"

    preferences {
      min_healthy_percentage = 0
    }
  }

  # 용량 공급자가 관리하는 ASG 라는 표시
  tag {
    key                 = "AmazonECSManaged"
    value               = "true"
    propagate_at_launch = true
  }

  tag {
    key                 = "Name"
    value               = local.obs_name
    propagate_at_launch = true
  }

  lifecycle {
    ignore_changes = [desired_capacity]
  }
}

resource "aws_ecs_capacity_provider" "obs" {
  name = local.obs_name

  auto_scaling_group_provider {
    auto_scaling_group_arn         = aws_autoscaling_group.obs.arn
    managed_termination_protection = "DISABLED"

    # 크기는 ASG 가 1 로 고정한다
    managed_scaling {
      status = "DISABLED"
    }
  }
}
