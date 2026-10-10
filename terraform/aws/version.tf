terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9" # ephemeral random_bytes 는 3.9 부터 (random_password 는 3.7)
    }
    # secretsmanager 스택에서 JWT 개인키를 만든다 (ephemeral — 상태에 남지 않는다)
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.1"
    }
    # secretsmanager 스택에서 application/<서비스>/secrets.sops.yml 복호화에 쓴다
    sops = {
      source  = "carlpett/sops"
      version = "~> 1.4"
    }
  }
}
