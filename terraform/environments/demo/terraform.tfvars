# Demo environment specific values
region = "ap-southeast-1"

tags = {
  Environment = "demo"
  Purpose     = "CDC Pipeline Demo"
  Owner       = "DevOps Team"
  CostCenter  = "Development"
}

# ไม่ต้องใส่ eks_node_groups ที่นี่ เพราะ define ใน main.tf แล้ว