module "sops_grandis_nova" {
  source = "../../_modules/sops"

  region           = var.aws_region
  common_alias     = "sops-grandis-nova"
  secure_alias     = "secure_sops-grandis-nova"
  role_name_prefix = "${var.product}-sops"
}
