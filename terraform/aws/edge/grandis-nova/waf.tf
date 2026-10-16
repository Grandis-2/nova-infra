# WAF — CloudFront(글로벌)에만 건다.
# ALB 는 CloudFront 대역 · 비밀 헤더 요청만 받으므로 ALB 에 다시 걸면 같은 요청을 두 번 검사하고 오탐도 두 번 난다
locals {
  managed_rule_groups = [
    { name = "AWSManagedRulesCommonRuleSet", priority = 10 },
    { name = "AWSManagedRulesKnownBadInputsRuleSet", priority = 20 },
    { name = "AWSManagedRulesAmazonIpReputationList", priority = 30 },
  ]

  # 그룹 안에서 차단 대신 표시(label)만 하는 규칙. BODY 둘은 아래 규칙이 허용 경로 밖에서 다시 막는다
  #   EC2MetaDataSSRF_BODY   카카오 콜백 본문의 redirectUri(로컬 개발이면 http://localhost:5173/…)가 걸린다 → SsrfBodyExceptKakaoCallback
  #   EC2MetaDataSSRF_COOKIE 프런트(Auth.js) 쿠키에 URL 이 담겨 걸린다. API 는 받은 URL 로 서버가 요청하지 않아 표시만 남긴다
  #   SizeRestrictions_BODY  본문 8KB 상한. 관리자 사진 업로드(파일이 본문)는 넘고, 사진이 많은 상품 등록도 넘을 수 있다 → SizeBodyExceptAdminUpload
  #                          두 경로는 대신 UploadContentLengthLimit 이 막고, 정확한 상한은 앱이 지킨다(사진 10MB · 요청 11MB, 상품 등록 256KB)
  #   GenericLFI_BODY        본문의 ../ 같은 경로 이동. 사진 업로드는 압축된 이미지 바이트에 우연히 ../ 가 생겨 걸린다 → BodyPatternExceptImageUpload
  #   CrossSiteScripting_BODY 본문의 XSS 패턴. 사진 바이트 · 메타데이터(XMP 의 xmlns)가 걸린다 → BodyPatternExceptImageUpload
  managed_rule_overrides = {
    AWSManagedRulesCommonRuleSet = ["EC2MetaDataSSRF_BODY", "EC2MetaDataSSRF_COOKIE", "SizeRestrictions_BODY", "GenericLFI_BODY", "CrossSiteScripting_BODY"]
  }
  ssrf_body_label   = "awswaf:managed:aws:core-rule-set:EC2MetaDataSSRF_Body"
  ssrf_allowed_path = "/api/v1/auth/kakao/callback"

  # 경로 둘을 or 로 묶으면 provider 스키마의 문장 깊이(3단)를 넘어 정규식 하나로 쓴다. 끝까지 일치라 /products/{id} 같은 하위 경로는 빠지지 않는다
  size_body_label         = "awswaf:managed:aws:core-rule-set:SizeRestrictions_Body"
  size_body_allowed_regex = "^/api/v1/admin/(images|products)$"

  # 본문 경로 이동 · XSS 검사는 사진 업로드(POST)에서만 뺀다. 본문이 이진 파일이라 텍스트 패턴 검사는 오탐만 낸다. 상품 등록(JSON)은 그대로 막는다
  # 전제: 앱이 JPEG · PNG 만 받아 다시 인코딩한 결과만 저장하고, 파일 이름 · 폼 값을 되돌려 주지 않는다. SVG · 원본 저장이 생기면 이 예외를 다시 본다
  lfi_body_label                  = "awswaf:managed:aws:core-rule-set:GenericLFI_Body"
  xss_body_label                  = "awswaf:managed:aws:core-rule-set:CrossSiteScripting_Body"
  body_pattern_allowed_path_regex = "^/api/v1/admin/images$"

  # 위 두 경로(POST)의 Content-Length 상한 10,599,999바이트. 사진은 한 요청에 한 장(10MiB = 10,485,760)이라 멀티파트 머리 · 경계 몫으로 약 110KB 를 더 둔다
  # WAF 는 본문 앞 16KB 만 보므로 헤더로 판단한다. 헤더가 없으면(chunked) 막힌다
  # 앱의 사진 상한(CatalogDefaults)이나 한 요청의 장 수를 바꾸면 이 값도 고친다
  upload_content_length_regex = "^([0-9]{1,7}|10[0-5][0-9]{5})$"
  frontend_origin             = "https://www.grandis-nova.link" # 앱 CORS 허용 목록(common:cors CorsDefaults)에 있는 출처

  # 대기열(줄 서기 POST · 조회 GET). 오픈 때 줄 서기가 한꺼번에 몰리고 대기자는 2~4초마다 조회하므로
  # 같은 공인 IP(회사 · 학교 · 통신사 NAT) 뒤에 여럿이면 ApiRateLimit 에 닿는다. 이 경로는 그 규칙에서 빼고 QueueRateLimit 으로 따로 센다
  queue_path = "/api/v1/preorders/queue"
}

resource "aws_wafv2_web_acl" "cloudfront" {
  provider = aws.us_east_1

  name  = "${local.name_prefix}-cloudfront"
  scope = "CLOUDFRONT"

  default_action {
    allow {}
  }

  # 앱의 ApiResponse 실패 봉투와 같은 모양(WAF 응답이라 timestamp · traceId 는 null).
  # AWS 로 보내는 값이라 메시지는 ASCII 다. 프런트는 상태 코드 413 으로 문구를 정한다
  custom_response_body {
    key          = "upload_too_large"
    content_type = "APPLICATION_JSON"
    content = jsonencode({
      success   = false
      data      = null
      error     = { code = "VALIDATION_FAILED", message = "File is too large.", details = null }
      timestamp = null
      traceId   = null
    })
  }

  dynamic "rule" {
    for_each = local.managed_rule_groups

    content {
      name     = rule.value.name
      priority = rule.value.priority

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
            for_each = lookup(local.managed_rule_overrides, rule.value.name, [])
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

  # 위에서 표시만 한 본문 SSRF 를 카카오 콜백 밖에서는 다시 막는다 (관리형 그룹 10 뒤에 평가해야 라벨이 있다)
  rule {
    name     = "SsrfBodyExceptKakaoCallback"
    priority = 15

    action {
      dynamic "block" {
        for_each = var.waf_block_mode ? [1] : []
        content {}
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

  # 위에서 표시만 한 8KB 본문 상한을 관리자 사진 업로드 · 상품 등록(POST) 밖에서는 다시 막는다 (관리형 그룹 10 뒤에 평가해야 라벨이 있다)
  rule {
    name     = "SizeBodyExceptAdminUpload"
    priority = 16

    action {
      dynamic "block" {
        for_each = var.waf_block_mode ? [1] : []
        content {}
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
                    regex_string = local.size_body_allowed_regex

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
      metric_name                = "SizeBodyExceptAdminUpload"
      sampled_requests_enabled   = true
    }
  }

  # 8KB 검사에서 뺀 두 경로(POST)는 Content-Length 가 없거나 상한을 넘으면 본문이 앱에 닿기 전에 막는다.
  # 앱의 상한 초과와 같은 413 · 응답 봉투로 돌려준다 — 프런트가 413 으로 "파일이 너무 큽니다" 를 가른다.
  # WAF 응답은 앱의 CORS 를 거치지 않아 헤더를 직접 단다. 값이 고정이라 프런트 출처 하나만 둔다(apex 는 www 로 308 이동한다)
  rule {
    name     = "UploadContentLengthLimit"
    priority = 17

    action {
      dynamic "block" {
        for_each = var.waf_block_mode ? [1] : []
        content {
          custom_response {
            response_code            = 413
            custom_response_body_key = "upload_too_large"

            response_header {
              name  = "Access-Control-Allow-Origin"
              value = local.frontend_origin
            }

            response_header {
              name  = "Access-Control-Allow-Credentials"
              value = "true"
            }

            response_header {
              name  = "Vary"
              value = "Origin"
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
            regex_string = local.size_body_allowed_regex

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
        content {}
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
                    regex_string = local.body_pattern_allowed_path_regex

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

  # 한 IP 의 과도한 요청을 잠시 막는다. 대기열을 우회하려는 스크립트 요청을 줄인다.
  rule {
    name     = "ApiRateLimit"
    priority = 100

    action {
      dynamic "block" {
        for_each = var.waf_block_mode ? [1] : []
        content {}
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

        # /api/ 아래에서 대기열 경로만 뺀다
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
        content {}
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

        scope_down_statement {
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
