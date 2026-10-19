# WAF — CloudFront(글로벌)에만 건다.
# ALB 는 CloudFront 대역 · 비밀 헤더 요청만 받으므로 ALB 에 다시 걸면 같은 요청을 두 번 검사하고 오탐도 두 번 난다
locals {
  managed_rule_groups = [
    { name = "AWSManagedRulesCommonRuleSet", priority = 10 },
    { name = "AWSManagedRulesKnownBadInputsRuleSet", priority = 20 },
    { name = "AWSManagedRulesAmazonIpReputationList", priority = 30 },
  ]

  # 관리형 그룹의 알려진 규칙은 규칙마다 표시(count)만 하게 한다. 그룹 전체를 count 로 바꾸면 그룹 안의 차단 규칙에 걸린 순간
  # 그룹 평가가 멈춰 뒤 규칙의 라벨이 붙지 않는다(예외 경로에서 악성 본문이 빠진다). 규칙마다 count 면 모든 라벨이 붙는다.
  # 막는 것은 ManagedRuleBlock 하나가 라벨을 모아 봉투 응답으로 한다. 규칙마다 봉투 응답을 달면 응답 헤더가 웹 ACL 한도(100개)를 넘는다.
  # 여기 없는 규칙(AWS 가 새로 더한 것)은 그룹이 그대로 막는다(WAF 기본 403). 그때 아래 두 목록에 더한다.
  # 아래 다섯은 ManagedRuleBlock 에서 빼고 따로 다룬다(허용 경로 밖에서만 막거나, 표시만 남긴다)
  #   EC2MetaDataSSRF_BODY   카카오 콜백 본문의 redirectUri(로컬 개발이면 http://localhost:5173/…)가 걸린다 → SsrfBodyExceptKakaoCallback
  #   EC2MetaDataSSRF_COOKIE 프런트(Auth.js) 쿠키에 URL 이 담겨 걸린다. API 는 받은 URL 로 서버가 요청하지 않아 표시만 남긴다
  #   SizeRestrictions_BODY  본문 8KB 상한. 관리자 API(사진 업로드, 긴 상품 설명, 재고 · 재처리 일괄 요청)와 주문 생성(항목 50개 + 배송지, 약 10KB)은 넘을 수 있다 → SizeBodyExceptAllowed
  #                          두 곳은 대신 Content-Length 로 막는다 — 사진 업로드 11MB(UploadContentLengthLimit), 관리자 그 밖 512KB(AdminBodyContentLength),
  #                          주문 생성 64KB(OrderBodyContentLength). 관리자 API 는 ADMIN 토큰, 주문은 회원 토큰이 있어야 닿고, 필드별 상한은 앱이 지킨다
  #   GenericLFI_BODY        본문의 ../ 같은 경로 이동. 사진 업로드는 압축된 이미지 바이트에 우연히 ../ 가 생겨 걸린다 → BodyPatternExceptImageUpload
  #   CrossSiteScripting_BODY 본문의 XSS 패턴. 사진 바이트 · 메타데이터(XMP 의 xmlns)가 걸린다 → BodyPatternExceptImageUpload
  managed_count_rules = {
    AWSManagedRulesCommonRuleSet = [
      "NoUserAgent_HEADER", "UserAgent_BadBots_HEADER", "SizeRestrictions_QUERYSTRING", "SizeRestrictions_Cookie_HEADER", "SizeRestrictions_BODY",
      "SizeRestrictions_URIPATH", "EC2MetaDataSSRF_BODY", "EC2MetaDataSSRF_COOKIE", "EC2MetaDataSSRF_URIPATH", "EC2MetaDataSSRF_QUERYARGUMENTS",
      "GenericLFI_QUERYARGUMENTS", "GenericLFI_URIPATH", "GenericLFI_BODY", "RestrictedExtensions_URIPATH", "RestrictedExtensions_QUERYARGUMENTS",
      "GenericRFI_QUERYARGUMENTS", "GenericRFI_BODY", "GenericRFI_URIPATH", "CrossSiteScripting_COOKIE", "CrossSiteScripting_QUERYARGUMENTS",
      "CrossSiteScripting_BODY", "CrossSiteScripting_URIPATH",
    ]
    AWSManagedRulesKnownBadInputsRuleSet = [
      "JavaDeserializationRCE_BODY", "JavaDeserializationRCE_URIPATH", "JavaDeserializationRCE_QUERYSTRING", "JavaDeserializationRCE_HEADER",
      "Host_localhost_HEADER", "PROPFIND_METHOD", "ExploitablePaths_URIPATH", "Log4JRCE_QUERYSTRING", "Log4JRCE_BODY", "Log4JRCE_URIPATH",
      "Log4JRCE_HEADER", "ReactJSRCE_BODY",
    ]
    # AWSManagedIPDDoSList 는 AWS 기본값이 count 다
    AWSManagedRulesAmazonIpReputationList = ["AWSManagedIPReputationList", "AWSManagedReconnaissanceList"]
  }
  managed_label_prefix = { core = "awswaf:managed:aws:core-rule-set:", bad = "awswaf:managed:aws:known-bad-inputs:", ip = "awswaf:managed:aws:amazon-ip-list:" }
  # ManagedRuleBlock 이 막는 라벨. AWS 가 규칙(라벨)을 더하면 여기에 더한다. AWSManagedIPDDoSList 는 AWS 기본값대로 표시만 한다
  #   aws wafv2 describe-managed-rule-group --scope CLOUDFRONT --region us-east-1 --vendor-name AWS --name <그룹> --query AvailableLabels
  managed_block_labels = concat(
    [for l in [
      "NoUserAgent_Header", "BadBots_Header", "SizeRestrictions_QueryString", "SizeRestrictions_Cookie_Header", "SizeRestrictions_URIPath",
      "EC2MetaDataSSRF_URIPath", "EC2MetaDataSSRF_QueryArguments", "GenericLFI_QueryArguments", "GenericLFI_URIPath",
      "RestrictedExtensions_URIPath", "RestrictedExtensions_QueryArguments", "GenericRFI_QueryArguments", "GenericRFI_Body", "GenericRFI_URIPath",
      "CrossSiteScripting_Cookie", "CrossSiteScripting_QueryArguments", "CrossSiteScripting_URIPath",
    ] : "${local.managed_label_prefix.core}${l}"],
    [for l in [
      "JavaDeserializationRCE_Body", "JavaDeserializationRCE_URIPath", "JavaDeserializationRCE_QueryString", "JavaDeserializationRCE_Header",
      "Host_Localhost_Header", "Propfind_Method", "ExploitablePaths_URIPath",
      "Log4JRCE_QueryString", "Log4JRCE_Body", "Log4JRCE_URIPath", "Log4JRCE_Header", "ReactJSRCE_Body",
    ] : "${local.managed_label_prefix.bad}${l}"],
    [for l in ["AWSManagedIPReputationList", "AWSManagedReconnaissanceList"] : "${local.managed_label_prefix.ip}${l}"],
  )
  ssrf_body_label   = "awswaf:managed:aws:core-rule-set:EC2MetaDataSSRF_Body"
  ssrf_allowed_path = "/api/v1/auth/kakao/callback"

  size_body_label         = "awswaf:managed:aws:core-rule-set:SizeRestrictions_Body"
  admin_path_prefix       = "/api/v1/admin/"
  admin_login_path_prefix = "/api/v1/admin/session" # 토큰 없이 부르는 관리자 로그인. 8KB 예외에서 뺀다
  order_create_path       = "/api/v1/orders"
  # 8KB 검사에서 빼는 경로: 관리자 API 전체, 주문 생성(끝까지 일치)
  size_body_exempt_regex = "^/api/v1/admin/|^/api/v1/orders$"
  # 주문 생성 본문 상한 65,536바이트(64KB). 0 ~ 65536 만 맞는다
  order_content_length_regex = "^([0-9]{1,4}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-6])$"
  # 관리자 API(사진 업로드 제외) 본문 상한 524,288바이트(512KB). 0 ~ 524288 만 맞는다. 부족하면 이 값을 늘린다
  admin_content_length_regex = "^([0-9]{1,5}|[1-4][0-9]{5}|5[01][0-9]{4}|52[0-3][0-9]{3}|524[01][0-9]{2}|5242[0-7][0-9]|52428[0-8])$"

  # 본문 경로 이동 · XSS 검사는 사진 업로드(POST)에서만 뺀다. 본문이 이진 파일이라 텍스트 패턴 검사는 오탐만 낸다. 상품 등록(JSON)은 그대로 막는다
  # 전제: 앱이 JPEG · PNG 만 받아 다시 인코딩한 결과만 저장하고, 파일 이름 · 폼 값을 되돌려 주지 않는다. SVG · 원본 저장이 생기면 이 예외를 다시 본다
  lfi_body_label          = "awswaf:managed:aws:core-rule-set:GenericLFI_Body"
  xss_body_label          = "awswaf:managed:aws:core-rule-set:CrossSiteScripting_Body"
  image_upload_path_regex = "^/api/v1/admin/images$"

  # 사진 업로드(POST)의 Content-Length 상한 10,599,999바이트. 사진은 한 요청에 한 장(10MiB = 10,485,760)이라 멀티파트 머리 · 경계 몫으로 약 110KB 를 더 둔다
  # WAF 는 본문 앞 16KB 만 보므로 헤더로 판단한다. 헤더가 없으면(chunked) 막힌다
  # 앱의 사진 상한(CatalogDefaults)이나 한 요청의 장 수를 바꾸면 이 값도 고친다
  upload_content_length_regex = "^([0-9]{1,7}|10[0-5][0-9]{5})$"
  frontend_origin             = "https://www.grandis-nova.link" # 앱 CORS 허용 목록(common:cors CorsDefaults)에 있는 출처

  # 대기열(줄 서기 POST · 조회 GET). 오픈 때 줄 서기가 한꺼번에 몰리고 대기자는 2~4초마다 조회하므로
  # 같은 공인 IP(회사 · 학교 · 통신사 NAT) 뒤에 여럿이면 ApiRateLimit 에 닿는다. 이 경로는 그 규칙에서 빼고 QueueRateLimit 으로 따로 센다
  queue_path = "/api/v1/preorders/queue"

  # WAF 가 직접 끝내는 응답. 앱의 ApiResponse 실패 봉투와 같은 모양이고(timestamp · traceId 는 null), 앱을 거치지 않았다는 표시로 details.source 를 둔다.
  # 코드는 뜻이 같으면 앱(CommonErrorCode)의 이름을 쓰고, 앱의 FORBIDDEN(권한 없음)과 다른 보안 규칙 차단은 따로 둔다.
  # 메시지는 앱(CommonErrorCode)처럼 사용자에게 보여 줄 수 있는 한국어로 쓴다(프런트가 error.message 를 그대로 보여 준다).
  # 요청을 찾을 때는 응답 헤더 x-amz-cf-id 를 쓴다
  waf_errors = {
    request_blocked   = { code = "REQUEST_BLOCKED", message = "보안 정책에 따라 요청이 차단되었습니다." }
    too_many_requests = { code = "TOO_MANY_REQUESTS", message = "요청이 너무 많습니다. 잠시 후 다시 시도해 주세요." }
    body_too_large    = { code = "VALIDATION_FAILED", message = "요청 본문이 너무 큽니다." }
  }

  # WAF 응답은 앱의 CORS 를 거치지 않아 헤더를 직접 단다. 값이 고정이라 프런트 출처 하나만 둔다(apex 는 www 로 308 이동한다).
  # 브라우저 코드가 요청 ID(x-amz-cf-id, CloudFront 가 붙임)와 다시 시도할 시각(Retry-After)을 읽을 수 있게 노출한다
  cors_headers = {
    "Access-Control-Allow-Origin"      = local.frontend_origin
    "Access-Control-Allow-Credentials" = "true"
    "Access-Control-Expose-Headers"    = "Retry-After, X-Amz-Cf-Id"
    "Vary"                             = "Origin"
  }
  rate_limit_headers = merge(local.cors_headers, { "Retry-After" = "60" })
}

resource "aws_wafv2_web_acl" "cloudfront" {
  provider = aws.us_east_1

  name  = "${local.name_prefix}-cloudfront"
  scope = "CLOUDFRONT"

  default_action {
    allow {}
  }

  dynamic "custom_response_body" {
    for_each = local.waf_errors
    content {
      key          = custom_response_body.key
      content_type = "APPLICATION_JSON"
      content = jsonencode({
        success   = false
        data      = null
        error     = { code = custom_response_body.value.code, message = custom_response_body.value.message, details = { source = "edge" } }
        timestamp = null
        traceId   = null
      })
    }
  }

  dynamic "rule" {
    for_each = local.managed_rule_groups

    content {
      name     = rule.value.name
      priority = rule.value.priority

      # 알려진 규칙은 아래에서 규칙마다 count 로 바꾸므로, 그룹이 직접 막는 것은 목록에 없는(새) 규칙뿐이다
      override_action {
        dynamic "none" {
          for_each = var.waf_block_mode ? [1] : []
          content {}
        }

        dynamic "count" {
          for_each = var.waf_block_mode ? [] : [1]
          content {}
        }
      }

      statement {
        managed_rule_group_statement {
          vendor_name = "AWS"
          name        = rule.value.name

          dynamic "rule_action_override" {
            for_each = lookup(local.managed_count_rules, rule.value.name, [])
            content {
              name = rule_action_override.value
              action_to_use {
                count {}
              }
            }
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = rule.value.name
        sampled_requests_enabled   = true
      }
    }
  }

  # 관리형 그룹이 표시한 라벨 중 막을 것을 봉투 응답(403)으로 막는다. 그룹 셋(10 · 20 · 30) 뒤에 평가해야 라벨이 있다
  rule {
    name     = "ManagedRuleBlock"
    priority = 35

    action {
      dynamic "block" {
        for_each = var.waf_block_mode ? [1] : []
        content {
          custom_response {
            response_code            = 403
            custom_response_body_key = "request_blocked"

            dynamic "response_header" {
              for_each = local.cors_headers
              content {
                name  = response_header.key
                value = response_header.value
              }
            }
          }
        }
      }

      dynamic "count" {
        for_each = var.waf_block_mode ? [] : [1]
        content {}
      }
    }

    statement {
      or_statement {
        dynamic "statement" {
          for_each = local.managed_block_labels
          content {
            label_match_statement {
              scope = "LABEL"
              key   = statement.value
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "ManagedRuleBlock"
      sampled_requests_enabled   = true
    }
  }

  # 위에서 표시만 한 본문 SSRF 를 카카오 콜백 밖에서는 다시 막는다 (관리형 그룹 10 뒤에 평가해야 라벨이 있다)
  rule {
    name     = "SsrfBodyExceptKakaoCallback"
    priority = 15

    action {
      dynamic "block" {
        for_each = var.waf_block_mode ? [1] : []
        content {
          custom_response {
            response_code            = 403
            custom_response_body_key = "request_blocked"

            dynamic "response_header" {
              for_each = local.cors_headers
              content {
                name  = response_header.key
                value = response_header.value
              }
            }
          }
        }
      }

      dynamic "count" {
        for_each = var.waf_block_mode ? [] : [1]
        content {}
      }
    }

    statement {
      and_statement {
        statement {
          label_match_statement {
            scope = "LABEL"
            key   = local.ssrf_body_label
          }
        }

        statement {
          not_statement {
            statement {
              byte_match_statement {
                positional_constraint = "EXACTLY"
                search_string         = local.ssrf_allowed_path

                field_to_match {
                  uri_path {}
                }

                text_transformation {
                  priority = 0
                  type     = "NONE"
                }
              }
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "SsrfBodyExceptKakaoCallback"
      sampled_requests_enabled   = true
    }
  }

  # 위에서 표시만 한 8KB 본문 상한을 관리자 API · 주문 생성 밖에서는 다시 막는다 (관리형 그룹 10 뒤에 평가해야 라벨이 있다).
  # 두 곳은 아래 Content-Length 규칙이 막는다. 관리자 로그인(/api/v1/admin/session)은 토큰 없이 부를 수 있어 8KB 를 그대로 둔다
  rule {
    name     = "SizeBodyExceptAllowed"
    priority = 16

    action {
      dynamic "block" {
        for_each = var.waf_block_mode ? [1] : []
        content {
          custom_response {
            response_code            = 413
            custom_response_body_key = "body_too_large"

            dynamic "response_header" {
              for_each = local.cors_headers
              content {
                name  = response_header.key
                value = response_header.value
              }
            }
          }
        }
      }

      dynamic "count" {
        for_each = var.waf_block_mode ? [] : [1]
        content {}
      }
    }

    statement {
      and_statement {
        statement {
          label_match_statement {
            scope = "LABEL"
            key   = local.size_body_label
          }
        }

        statement {
          or_statement {
            statement {
              not_statement {
                statement {
                  regex_match_statement {
                    regex_string = local.size_body_exempt_regex

                    field_to_match {
                      uri_path {}
                    }

                    text_transformation {
                      priority = 0
                      type     = "NONE"
                    }
                  }
                }
              }
            }

            statement {
              byte_match_statement {
                positional_constraint = "STARTS_WITH"
                search_string         = local.admin_login_path_prefix

                field_to_match {
                  uri_path {}
                }

                text_transformation {
                  priority = 0
                  type     = "NONE"
                }
              }
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "SizeBodyExceptAllowed"
      sampled_requests_enabled   = true
    }
  }

  # 사진 업로드(POST)는 Content-Length 가 없거나 11MB 를 넘으면 본문이 앱에 닿기 전에 막는다.
  # 앱의 상한 초과와 같은 413 · 응답 봉투로 돌려준다 — 프런트가 413 으로 "파일이 너무 큽니다" 를 가른다
  rule {
    name     = "UploadContentLengthLimit"
    priority = 17

    action {
      dynamic "block" {
        for_each = var.waf_block_mode ? [1] : []
        content {
          custom_response {
            response_code            = 413
            custom_response_body_key = "body_too_large"

            dynamic "response_header" {
              for_each = local.cors_headers
              content {
                name  = response_header.key
                value = response_header.value
              }
            }
          }
        }
      }

      dynamic "count" {
        for_each = var.waf_block_mode ? [] : [1]
        content {}
      }
    }

    statement {
      and_statement {
        statement {
          byte_match_statement {
            positional_constraint = "EXACTLY"
            search_string         = "POST"

            field_to_match {
              method {}
            }

            text_transformation {
              priority = 0
              type     = "NONE"
            }
          }
        }

        statement {
          regex_match_statement {
            regex_string = local.image_upload_path_regex

            field_to_match {
              uri_path {}
            }

            text_transformation {
              priority = 0
              type     = "NONE"
            }
          }
        }

        statement {
          not_statement {
            statement {
              regex_match_statement {
                regex_string = local.upload_content_length_regex

                field_to_match {
                  single_header {
                    name = "content-length"
                  }
                }

                text_transformation {
                  priority = 0
                  type     = "NONE"
                }
              }
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "UploadContentLengthLimit"
      sampled_requests_enabled   = true
    }
  }

  # 위에서 표시만 한 본문 경로 이동 · XSS 검사를 사진 업로드(POST) 밖에서는 다시 막는다 (관리형 그룹 10 뒤에 평가해야 라벨이 있다)
  rule {
    name     = "BodyPatternExceptImageUpload"
    priority = 18

    action {
      dynamic "block" {
        for_each = var.waf_block_mode ? [1] : []
        content {
          custom_response {
            response_code            = 403
            custom_response_body_key = "request_blocked"

            dynamic "response_header" {
              for_each = local.cors_headers
              content {
                name  = response_header.key
                value = response_header.value
              }
            }
          }
        }
      }

      dynamic "count" {
        for_each = var.waf_block_mode ? [] : [1]
        content {}
      }
    }

    statement {
      and_statement {
        statement {
          or_statement {
            statement {
              label_match_statement {
                scope = "LABEL"
                key   = local.lfi_body_label
              }
            }

            statement {
              label_match_statement {
                scope = "LABEL"
                key   = local.xss_body_label
              }
            }
          }
        }

        statement {
          not_statement {
            statement {
              and_statement {
                statement {
                  byte_match_statement {
                    positional_constraint = "EXACTLY"
                    search_string         = "POST"

                    field_to_match {
                      method {}
                    }

                    text_transformation {
                      priority = 0
                      type     = "NONE"
                    }
                  }
                }

                statement {
                  regex_match_statement {
                    regex_string = local.image_upload_path_regex

                    field_to_match {
                      uri_path {}
                    }

                    text_transformation {
                      priority = 0
                      type     = "NONE"
                    }
                  }
                }
              }
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "BodyPatternExceptImageUpload"
      sampled_requests_enabled   = true
    }
  }

  # 8KB 검사에서 뺀 관리자 API(사진 업로드 POST 제외)는 Content-Length 가 없거나 512KB 를 넘으면 앱에 닿기 전에 막는다.
  # 8KB 를 넘은 요청(라벨)만 본다 — 본문 없는 GET 이나 작은 요청은 Content-Length 가 없어도 지나간다
  rule {
    name     = "AdminBodyContentLength"
    priority = 19

    action {
      dynamic "block" {
        for_each = var.waf_block_mode ? [1] : []
        content {
          custom_response {
            response_code            = 413
            custom_response_body_key = "body_too_large"

            dynamic "response_header" {
              for_each = local.cors_headers
              content {
                name  = response_header.key
                value = response_header.value
              }
            }
          }
        }
      }

      dynamic "count" {
        for_each = var.waf_block_mode ? [] : [1]
        content {}
      }
    }

    statement {
      and_statement {
        statement {
          label_match_statement {
            scope = "LABEL"
            key   = local.size_body_label
          }
        }

        statement {
          byte_match_statement {
            positional_constraint = "STARTS_WITH"
            search_string         = local.admin_path_prefix

            field_to_match {
              uri_path {}
            }

            text_transformation {
              priority = 0
              type     = "NONE"
            }
          }
        }

        statement {
          not_statement {
            statement {
              and_statement {
                statement {
                  byte_match_statement {
                    positional_constraint = "EXACTLY"
                    search_string         = "POST"

                    field_to_match {
                      method {}
                    }

                    text_transformation {
                      priority = 0
                      type     = "NONE"
                    }
                  }
                }

                statement {
                  regex_match_statement {
                    regex_string = local.image_upload_path_regex

                    field_to_match {
                      uri_path {}
                    }

                    text_transformation {
                      priority = 0
                      type     = "NONE"
                    }
                  }
                }
              }
            }
          }
        }

        statement {
          not_statement {
            statement {
              regex_match_statement {
                regex_string = local.admin_content_length_regex

                field_to_match {
                  single_header {
                    name = "content-length"
                  }
                }

                text_transformation {
                  priority = 0
                  type     = "NONE"
                }
              }
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AdminBodyContentLength"
      sampled_requests_enabled   = true
    }
  }

  # 8KB 검사에서 뺀 주문 생성은 Content-Length 가 없거나 64KB 를 넘으면 앱에 닿기 전에 막는다. 8KB 를 넘은 요청(라벨)만 본다
  rule {
    name     = "OrderBodyContentLength"
    priority = 21

    action {
      dynamic "block" {
        for_each = var.waf_block_mode ? [1] : []
        content {
          custom_response {
            response_code            = 413
            custom_response_body_key = "body_too_large"

            dynamic "response_header" {
              for_each = local.cors_headers
              content {
                name  = response_header.key
                value = response_header.value
              }
            }
          }
        }
      }

      dynamic "count" {
        for_each = var.waf_block_mode ? [] : [1]
        content {}
      }
    }

    statement {
      and_statement {
        statement {
          label_match_statement {
            scope = "LABEL"
            key   = local.size_body_label
          }
        }

        statement {
          byte_match_statement {
            positional_constraint = "EXACTLY"
            search_string         = local.order_create_path

            field_to_match {
              uri_path {}
            }

            text_transformation {
              priority = 0
              type     = "NONE"
            }
          }
        }

        statement {
          not_statement {
            statement {
              regex_match_statement {
                regex_string = local.order_content_length_regex

                field_to_match {
                  single_header {
                    name = "content-length"
                  }
                }

                text_transformation {
                  priority = 0
                  type     = "NONE"
                }
              }
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "OrderBodyContentLength"
      sampled_requests_enabled   = true
    }
  }

  # 한 IP 의 과도한 요청을 잠시 막는다. 대기열을 우회하려는 스크립트 요청을 줄인다.
  rule {
    name     = "ApiRateLimit"
    priority = 100

    action {
      dynamic "block" {
        for_each = var.waf_block_mode ? [1] : []
        content {
          custom_response {
            response_code            = 429
            custom_response_body_key = "too_many_requests"

            dynamic "response_header" {
              for_each = local.rate_limit_headers
              content {
                name  = response_header.key
                value = response_header.value
              }
            }
          }
        }
      }

      dynamic "count" {
        for_each = var.waf_block_mode ? [] : [1]
        content {}
      }
    }

    statement {
      rate_based_statement {
        limit              = var.api_rate_limit_per_5min
        aggregate_key_type = "IP"

        # /api/ 아래에서 대기열 경로와 부하 시험 요청을 뺀다
        scope_down_statement {
          and_statement {
            statement {
              byte_match_statement {
                positional_constraint = "STARTS_WITH"
                search_string         = "/api/"

                field_to_match {
                  uri_path {}
                }

                text_transformation {
                  priority = 0
                  type     = "NONE"
                }
              }
            }

            statement {
              not_statement {
                statement {
                  byte_match_statement {
                    positional_constraint = "STARTS_WITH"
                    search_string         = local.queue_path

                    field_to_match {
                      uri_path {}
                    }

                    text_transformation {
                      priority = 0
                      type     = "NONE"
                    }
                  }
                }
              }
            }

            # 부하 시험 헤더가 맞으면 세지 않는다
            statement {
              not_statement {
                statement {
                  byte_match_statement {
                    positional_constraint = "EXACTLY"
                    search_string         = local.loadtest_header

                    field_to_match {
                      single_header {
                        name = "x-nova-loadtest"
                      }
                    }

                    text_transformation {
                      priority = 0
                      type     = "NONE"
                    }
                  }
                }
              }
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "ApiRateLimit"
      sampled_requests_enabled   = true
    }
  }

  # 대기열 전용 한도(줄 서기 · 조회). 앱이 회원별 조회 간격(Retry-After)을 정하므로 여기서는 NAT 뒤 다수를 막지 않을 만큼 넉넉히 둔다.
  # 산정: 대기자 한 명이 5분에 약 100건(2~4초 간격 조회) + 오픈 때 줄 서기. 통신사 CGNAT 은 공인 IP 하나 뒤에
  #       수천 명이 있을 수 있어 약 3,000명분(300,000)으로 잡았다. 한 IP 의 과다 요청은 WAF 가 아니라
  #       앱(인증 · Retry-After)이 맡는다. 줄이려면 queue_rate_limit_per_5min 만 바꾼다
  rule {
    name     = "QueueRateLimit"
    priority = 110

    action {
      dynamic "block" {
        for_each = var.waf_block_mode ? [1] : []
        content {
          custom_response {
            response_code            = 429
            custom_response_body_key = "too_many_requests"

            dynamic "response_header" {
              for_each = local.rate_limit_headers
              content {
                name  = response_header.key
                value = response_header.value
              }
            }
          }
        }
      }

      dynamic "count" {
        for_each = var.waf_block_mode ? [] : [1]
        content {}
      }
    }

    statement {
      rate_based_statement {
        limit              = var.queue_rate_limit_per_5min
        aggregate_key_type = "IP"

        # 대기열 경로이고 부하 시험 헤더가 없는 요청만 센다
        scope_down_statement {
          and_statement {
            statement {
              byte_match_statement {
                positional_constraint = "STARTS_WITH"
                search_string         = local.queue_path

                field_to_match {
                  uri_path {}
                }

                text_transformation {
                  priority = 0
                  type     = "NONE"
                }
              }
            }

            statement {
              not_statement {
                statement {
                  byte_match_statement {
                    positional_constraint = "EXACTLY"
                    search_string         = local.loadtest_header

                    field_to_match {
                      single_header {
                        name = "x-nova-loadtest"
                      }
                    }

                    text_transformation {
                      priority = 0
                      type     = "NONE"
                    }
                  }
                }
              }
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "QueueRateLimit"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name_prefix}-cloudfront"
    sampled_requests_enabled   = true
  }

  tags = { Name = "${local.name_prefix}-cloudfront-waf" }
}
