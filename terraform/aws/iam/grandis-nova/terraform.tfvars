# 배포 역할(OIDC)을 받을 수 있는 저장소. OIDC sub 클레임의 repo: 뒤 부분과 같아야 한다.
# be 는 immutable subject 를 써서 OWNER@ID/REPO@ID 형식이다. 확인:
#   gh api repos/Grandis-2/be/actions/oidc/customization/sub   (sub_claim_prefix)
# 저장소를 옮기면 ID 가 바뀌므로 다시 확인한다.
github_repositories = ["Grandis-2@336932992/be@1374151454"]

# mock 전용 배포 역할(github_deploy_mock.tf). 확인: gh api repos/Grandis-2/mock/actions/oidc/customization/sub
github_mock_repositories = ["Grandis-2@336932992/mock@1365107413"]

# 계정에 GitHub OIDC 공급자가 이미 있다 (token.actions.githubusercontent.com). 새로 만들지 않고 조회해서 쓴다
create_github_oidc_provider = false

