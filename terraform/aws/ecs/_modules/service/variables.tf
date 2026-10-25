variable "name" {
  description = "서비스 이름 (nova-prod-preorder 처럼 접두사까지 포함)"
  type        = string
}

variable "cluster_arn" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "image" {
  description = "컨테이너 이미지 (repo:tag)"
  type        = string
}

variable "cpu" {
  type = number
}

variable "memory" {
  type = number
}

variable "port" {
  description = "컨테이너가 듣는 포트. 0 이면 포트를 노출하지 않는다(컨슈머·배치)"
  type        = number
  default     = 8080
}

variable "desired_count" {
  type    = number
  default = 1
}

variable "subnet_ids" {
  type = list(string)
}

variable "security_group_ids" {
  type = list(string)
}

variable "execution_role_arn" {
  type = string
}

variable "task_role_arn" {
  type = string
}

variable "environment" {
  description = "평문 환경변수"
  type        = map(string)
  default     = {}
}

variable "secrets" {
  description = "환경변수 이름 -> Secrets Manager / SSM ARN (json 키 포함 가능)"
  type        = map(string)
  default     = {}
}

variable "log_retention_days" {
  type    = number
  default = 14
}

variable "use_spot" {
  description = "늘어나는 태스크를 FARGATE_SPOT 으로 띄울지 여부 (온디맨드로 남길 수는 on_demand_base)"
  type        = bool
  default     = false
}

variable "create_service" {
  description = "false 면 태스크 정의만 만든다 (배치처럼 스케줄로 실행하는 경우)"
  type        = bool
  default     = true
}

variable "service_connect_namespace" {
  description = "Service Connect 에 쓰는 Cloud Map 네임스페이스 ARN"
  type        = string
  default     = ""
}

variable "service_connect_dns_name" {
  description = "다른 서비스가 부르는 이름 (예: preorder.nova.local). 비우면 클라이언트로만 참여한다"
  type        = string
  default     = ""
}

variable "health_check_grace_period" {
  description = "ALB 헬스체크 유예 시간(초). 스프링 기동 시간을 감안한다"
  type        = number
  default     = 120
}

variable "health_check_command" {
  description = "컨테이너 자체 헬스체크 명령. 비우면 설정하지 않는다"
  type        = list(string)
  default     = []
}

variable "min_capacity" {
  type    = number
  default = 0
}

variable "max_capacity" {
  type    = number
  default = 0
}

variable "min_capacity_by_app" {
  description = "true 면 min_capacity 를 처음 만들 때만 넣고, 그 뒤 앱이 바꾼 값을 되돌리지 않는다"
  type        = bool
  default     = false
}

variable "cpu_target" {
  description = "CPU 목표 사용률(%). 0 이면 CPU 기반 스케일링을 걸지 않는다"
  type        = number
  default     = 60
}

variable "request_count_target" {
  description = "타깃당 분당 요청 수 목표. 0 이면 쓰지 않는다 (alb_resource_label 과 함께 쓴다)"
  type        = number
  default     = 0
}

variable "burst_cpu" {
  description = "순간 폭주 증설(burst.tf): CPU(%)가 이 값을 2번 연속 넘으면 바로 늘린다. 0 이면 쓰지 않는다"
  type        = number
  default     = 70
}

variable "burst_requests_per_task" {
  description = "순간 폭주 증설(burst.tf): 태스크 하나가 1분에 받은 요청이 이 값을 넘으면 바로 늘린다. 0 이면 쓰지 않는다 (routes 가 있는 서비스만)"
  type        = number
  default     = 0
}

variable "alarm_topic_arn" {
  description = "순간 폭주 증설 경보를 알릴 SNS 토픽(Slack). 비우면 알리지 않고 늘리기만 한다"
  type        = string
  default     = ""
}

variable "queue_backlog" {
  description = "큐 적체 기반 스케일링 설정. 컨슈머 전용. 큐가 여럿이면 메시지 수를 더한다. 태스크 수는 AWS/ECS 의 LiveTaskCount 를 쓴다"
  type = object({
    queue_names     = list(string)
    target_per_task = number
  })
  default = null

  validation {
    condition     = var.queue_backlog == null || (length(var.queue_backlog.queue_names) >= 1 && length(var.queue_backlog.queue_names) <= 8)
    error_message = "queue_backlog.queue_names 는 1~8개다 (지표 수식 한도 10개 중 태스크 수 · 결과식이 2개를 쓴다)."
  }
}

variable "stop_timeout" {
  description = "SIGTERM 뒤 SIGKILL 까지 기다리는 시간(초). null 이면 ECS 기본값(30초). Fargate 상한 120"
  type        = number
  default     = null
}

variable "enable_execute_command" {
  description = "ECS Exec(컨테이너 셸 접속) 허용 여부"
  type        = bool
  default     = true
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "extra_port" {
  description = "앱 포트 외에 여는 포트 (management.server.port 등). 없으면 0"
  type        = number
  default     = 0
}

variable "cpu_architecture" {
  description = "이미지 아키텍처. 이미지를 빌드한 플랫폼과 같아야 한다 (X86_64 | ARM64)"
  type        = string
  default     = "X86_64"

  validation {
    condition     = contains(["X86_64", "ARM64"], var.cpu_architecture)
    error_message = "cpu_architecture 는 X86_64 또는 ARM64 입니다."
  }
}

variable "discovery_name" {
  description = "서비스 키 (예: preorder). 태그에 쓴다"
  type        = string
  default     = ""
}

variable "singleton" {
  description = "동시에 한 개만 떠야 하는 앱. 롤링 배포 때 옛 태스크를 먼저 내린다"
  type        = bool
  default     = false
}

variable "on_demand_base" {
  description = "use_spot 일 때 온디맨드로 유지할 태스크 수. 0 이면 전부 Spot"
  type        = number
  default     = 1
}

variable "service_key" {
  description = "서비스 키 (application 폴더 이름). 타깃 그룹 태그에 쓴다"
  type        = string
}

variable "routes" {
  description = "ALB 경로 규칙 (service.yml 의 routes). 비우면 ALB 뒤에 두지 않는다"
  type = list(object({
    priority = number
    paths    = list(string)
    methods  = list(string)
  }))
  default = []
}

variable "health" {
  description = "ALB 헬스체크 (routes 가 있을 때만 쓴다)"
  type = object({
    port    = number
    path    = string
    matcher = string
  })
  default = null
}

variable "lb_algorithm" {
  description = "타깃 그룹의 요청 분배 방식 (service.yml 의 lb_algorithm). round_robin | least_outstanding_requests"
  type        = string
  default     = "round_robin"

  validation {
    condition     = contains(["round_robin", "least_outstanding_requests"], var.lb_algorithm)
    error_message = "lb_algorithm 은 round_robin | least_outstanding_requests 다."
  }
}

variable "vpc_id" {
  description = "타깃 그룹을 만들 VPC"
  type        = string
  default     = null
}

variable "listener_arn" {
  description = "규칙을 걸 ALB 리스너"
  type        = string
  default     = null
}

variable "alb_arn_suffix" {
  description = "ALB ARN 접미사. 요청 수 기반 스케일링 지표에 쓴다"
  type        = string
  default     = ""
}

variable "origin_verify_header" {
  description = "CloudFront 만 붙이는 원본 확인 헤더. 이 헤더가 있어야 규칙에 걸린다"
  type = object({
    name  = string
    value = string
  })
  default   = null
  sensitive = true
}

variable "blue_green" {
  description = "ECS 자체 Blue/Green 으로 배포할지. false 면 롤링"
  type        = bool
  default     = false
}

variable "bake_time_in_minutes" {
  description = "Blue/Green: 트래픽을 돌린 뒤 옛 버전을 남겨 두는 시간(분). 이 동안은 바로 되돌릴 수 있다"
  type        = number
  default     = 5
}

variable "lb_role_arn" {
  description = "Blue/Green: ECS 가 리스너 규칙 · 타깃 그룹을 바꿀 때 쓰는 역할 (AmazonECSInfrastructureRolePolicyForLoadBalancers)"
  type        = string
  default     = ""
}
