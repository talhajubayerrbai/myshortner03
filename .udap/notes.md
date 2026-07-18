# myshortner03 — Working Notes

## Project
- URL shortener: Python/FastAPI + SQLAlchemy + Alembic + PostgreSQL on RDS
- EC2 t3.micro (Amazon Linux 2023) + RDS PostgreSQL 15 t3.micro
- Nginx reverse proxy on port 80, app on 127.0.0.1:8000 (Gunicorn + UvicornWorker)
- Default VPC reused (probe confirmed: vpc-03b105b2b8dbab607, 6 subnets)
- No tests per user request

## Decisions
- FastAPI chosen (not in scaffold catalog, written manually)
- Amazon Linux 2023 (dnf/yum), SSH user = ec2-user
- RDS single-AZ, skip_final_snapshot=true, deletion_protection=false (Tier 1)
- alembic.ini sqlalchemy.url left empty; env.py overrides from DATABASE_URL env var
  (avoids configparser interpolation issues with special chars in passwords)
- DB_PASSWORD and SECRET_KEY are alphanumeric-only (generated via set_pipeline_secret)
- EIP used for stable public IP (verified as terraform output, not echoed from secret)

## Status
- [x] Architecture written
- [x] Pipeline written
- [x] Plan approved
- [x] All files generated
- [ ] validate_project
- [ ] Secrets set
- [ ] Repo pushed
- [ ] Deployed

## Secrets needed
- DB_PASSWORD — alphanumeric 24 chars
- SECRET_KEY — alphanumeric 32 chars

## Known pitfalls to watch
- Alembic: env.py reads DATABASE_URL from environment, NOT alembic.ini (configparser % issue)
- Nginx default site removed before adding vhost (Amazon Linux 2023 uses /etc/nginx/conf.d/)
- ansible copy module used for app source (no git clone needed — CI copies the workspace)
- RDS takes ~5-8 min to provision — provision stage timeout_minutes=30
