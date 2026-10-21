variable "queues" {
  description = "큐 이름. 백엔드 설정의 큐 이름과 같아야 한다"
  type        = list(string)
  default = [
    "preorder-register",  # preorder → worker : 외부 예약 등록
    "preorder-cancel",    # preorder → worker : 외부 예약 취소
    "draw-register",      # order → worker : 럭키드로우 응모 전달 · 추첨 요청
    "preorder-events",    # order, waitingroom, catalog → preorder
    "order-events",       # preorder, catalog, payment → order
    "payment-events",     # order → payment
    "notification",       # preorder, order → member : 알림
    "waitingroom-events", # preorder → waitingroom
    "catalog-events",     # order, preorder → catalog : 일반 상품 판매 준비 · 회차 일정 변경
    "admin-alert",        # preorder, order → member : 관리자 알림
  ]
}

variable "visibility_timeout" {
  description = "가시성 타임아웃(초). 컨슈머가 수신 시 따로 지정하지 않으면 이 값을 쓴다"
  type        = number
  default     = 360
}

variable "max_receive_count" {
  description = "수신 횟수가 이 값을 넘으면 DLQ 로 보낸다"
  type        = number
  default     = 5
}
