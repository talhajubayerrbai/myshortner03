# -- Data sources (reuse default VPC from probe) ------------------------------
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Look up the existing RDS SG by name -- Terraform read-only, never destroyed.
data "aws_security_group" "rds" {
  filter {
    name   = "group-name"
    values = ["${var.project_name}-rds-sg"]
  }
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# -- SSH Key Pair --------------------------------------------------------------
# NO ignore_changes on public_key: if SSH_PUBLIC_KEY rotates, Terraform must
# replace the key pair (and cascade to the EC2 instance) so the new instance
# is seeded with the current public key at launch.
resource "aws_key_pair" "app" {
  key_name   = "${var.project_name}-key"
  public_key = var.ssh_public_key

  tags = {
    Project   = var.project_name
    ManagedBy = "udap"
  }
}

# -- Security Groups ----------------------------------------------------------
resource "aws_security_group" "app" {
  name        = "${var.project_name}-app-sg"
  description = "App server security group"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # revoke_rules_on_delete strips inline ingress/egress rules owned BY this SG
  # before the DeleteSecurityGroup call. It does NOT revoke cross-SG rules on
  # other groups (e.g. the RDS SG) that reference this SG as a source; those
  # are handled explicitly in the destroy-time provisioner below.
  revoke_rules_on_delete = true

  # Destroy-time provisioner:
  # Step 1 — Revoke any cross-SG references to this SG that exist on OTHER
  #   security groups (specifically the RDS SG ingress rule added by
  #   aws_security_group_rule.rds_from_app). AWS returns DependencyViolation
  #   if DeleteSecurityGroup is called while any other SG still lists this SG
  #   as a source in one of its rules. Terraform's implicit dependency ordering
  #   should destroy aws_security_group_rule.rds_from_app first, but if the
  #   rule is absent from state (e.g. first destroy after the rule was added
  #   without a fresh apply, or a partial state) Terraform skips it and the
  #   rule remains in AWS — causing the 15-minute retry loop + failure.
  #   This step makes the provisioner idempotent: it detects and removes any
  #   remaining cross-SG references regardless of Terraform state.
  # Step 2 — Poll until all ENIs still associated with this SG have detached.
  #   EC2 instance termination is asynchronous — the ENI can remain "in-use"
  #   for up to ~60 s after the instance reaches "terminated".
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      SG_ID="${self.id}"

      echo "=== Step 1: Revoke cross-SG references to $SG_ID from other security groups ==="
      REFS=$(aws ec2 describe-security-groups \
        --filters "Name=ip-permission.group-id,Values=$SG_ID" \
        --query 'SecurityGroups[*].{GroupId:GroupId,Permissions:IpPermissions}' \
        --output json 2>/dev/null || echo '[]')

      echo "$REFS" | python3 -c "
import json, sys, subprocess
groups = json.load(sys.stdin)
for g in groups:
    gid = g['GroupId']
    perms_to_revoke = []
    for perm in g.get('Permissions', []):
        user_pairs = [p for p in perm.get('UserIdGroupPairs', []) if p.get('GroupId') == '$SG_ID']
        if user_pairs:
            perms_to_revoke.append({
                'IpProtocol': perm['IpProtocol'],
                'FromPort': perm.get('FromPort', 0),
                'ToPort': perm.get('ToPort', 0),
                'UserIdGroupPairs': user_pairs
            })
    if perms_to_revoke:
        print(f'Revoking {len(perms_to_revoke)} rule(s) from SG {gid} that reference $SG_ID')
        cmd = ['aws', 'ec2', 'revoke-security-group-ingress',
               '--group-id', gid,
               '--ip-permissions', json.dumps(perms_to_revoke)]
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            print(f'Warning: revoke failed for {gid}: {result.stderr}')
        else:
            print(f'Successfully revoked rules from {gid}')
"

      echo "=== Step 2: Wait for ENIs attached to $SG_ID to detach ==="
      for i in $(seq 1 30); do
        COUNT=$(aws ec2 describe-network-interfaces \
          --filters "Name=group-id,Values=$SG_ID" "Name=status,Values=in-use" \
          --query 'length(NetworkInterfaces)' \
          --output text 2>/dev/null || echo "0")
        if [ "$COUNT" = "0" ] || [ "$COUNT" = "None" ]; then
          echo "No in-use ENIs remaining after $((i * 10 - 10))s. Proceeding with SG deletion."
          exit 0
        fi
        echo "Attempt $i/30: $COUNT ENI(s) still in-use, sleeping 10s..."
        sleep 10
      done
      echo "Timed out waiting for ENIs to detach — proceeding anyway."
    EOT
  }

  lifecycle {
    ignore_changes = [ingress, egress]
  }

  tags = {
    Project   = var.project_name
    ManagedBy = "udap"
  }
}

# Explicitly manage the RDS SG ingress rule that allows the app SG to reach
# PostgreSQL. By owning this rule in Terraform, it is destroyed BEFORE
# aws_security_group.app is deleted, eliminating the DependencyViolation that
# occurs when the external RDS SG still references the app SG as a source.
# The destroy-time provisioner on aws_security_group.app provides a second
# layer of defence: it revokes any remaining cross-SG references via AWS CLI
# before the DeleteSecurityGroup API call is made, handling cases where this
# rule is absent from Terraform state.
resource "aws_security_group_rule" "rds_from_app" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = data.aws_security_group.rds.id
  source_security_group_id = aws_security_group.app.id
  description              = "Allow app SG to reach PostgreSQL"
}

# -- RDS Subnet Group ---------------------------------------------------------
resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-db-subnet-group"
  subnet_ids = data.aws_subnets.default.ids

  tags = {
    Project   = var.project_name
    ManagedBy = "udap"
  }
}

# -- RDS PostgreSQL ------------------------------------------------------------
resource "aws_db_instance" "postgres" {
  identifier        = "${var.project_name}-db"
  engine            = "postgres"
  engine_version    = "15"
  instance_class    = var.db_instance_class
  allocated_storage = 20
  storage_type      = "gp2"

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [data.aws_security_group.rds.id]

  publicly_accessible     = false
  skip_final_snapshot     = true
  deletion_protection     = false
  backup_retention_period = 0
  multi_az                = false

  lifecycle {
    ignore_changes = [vpc_security_group_ids, password]
  }

  tags = {
    Project   = var.project_name
    ManagedBy = "udap"
  }
}

# -- EC2 Instance -------------------------------------------------------------
resource "aws_instance" "app" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.app.key_name
  subnet_id              = tolist(data.aws_subnets.default.ids)[0]
  vpc_security_group_ids = [aws_security_group.app.id]

  tags = {
    Name      = "${var.project_name}-app"
    Project   = var.project_name
    ManagedBy = "udap"
  }

  depends_on = [aws_db_instance.postgres]
}

# -- Elastic IP ---------------------------------------------------------------
resource "aws_eip" "app" {
  instance = aws_instance.app.id
  domain   = "vpc"

  tags = {
    Project   = var.project_name
    ManagedBy = "udap"
  }
}
