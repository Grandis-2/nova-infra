# 생성 비밀의 버전. 번호를 올리면 그 비밀을 새 값으로 바꾼다 (variables.tf 의 secret_versions)
secret_versions = {
  "member/ADMIN_PASSWORDHASH" = 2 # cost 10 해시를 앱이 거절해 cost 12 로 다시 만든다. 원문(ops/member/admin-password)도 함께 바뀐다
}
