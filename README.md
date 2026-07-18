# myshortner03 — URL Shortener

A lightweight URL shortener built with **Python / FastAPI**, backed by **PostgreSQL on AWS RDS**, deployed to **EC2** via Ansible with Nginx as a reverse proxy.

## Architecture

```
Internet User
     │  HTTP :80
     ▼
EC2 App Server  (Nginx → Gunicorn/Uvicorn → FastAPI)
     │  Postgres :5432
     ▼
RDS PostgreSQL (single-AZ, us-east-1)
```

See `.udap/architecture.d2` for the full diagram.

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/shorten` | Shorten a URL |
| `GET` | `/{code}` | Redirect to the original URL |
| `GET` | `/health` | Health check |

### Shorten a URL

```bash
curl -X POST http://<EC2_IP>/shorten \
  -H "Content-Type: application/json" \
  -d '{"url": "https://example.com/very/long/path"}'
```

Response:
```json
{
  "short_url": "http://<EC2_IP>/aB3xY7z",
  "code": "aB3xY7z",
  "original_url": "https://example.com/very/long/path"
}
```

### Follow a short link

```bash
curl -L http://<EC2_IP>/aB3xY7z
```

## Running Locally

**Prerequisites:** Python 3.11+, PostgreSQL running locally.

```bash
# Clone and set up
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt

# Configure
export DATABASE_URL="postgresql://user:pass@localhost:5432/shortener"
export SECRET_KEY="your-secret-key"
export BASE_URL="http://localhost:8000"

# Run migrations
alembic upgrade head

# Start the server
uvicorn app.main:app --reload
```

API docs available at `http://localhost:8000/docs`.

## Deployment Pipeline

Managed by GitHub Actions via `.udap/pipeline.yaml`:

| Stage | What it does |
|-------|-------------|
| **provision** | Terraform apply: EC2 + EIP + RDS + security groups |
| **configure** | Ansible: install packages, copy app, write `.env`, run migrations, start services |
| **verify** | HTTP health check with retries against the EC2 public IP |

## Configuration (Environment Variables)

| Variable | Description | Source |
|----------|-------------|--------|
| `DATABASE_URL` | Full PostgreSQL connection URL | Built from secrets at configure time |
| `SECRET_KEY` | Application secret key | `DB_PASSWORD` secret |
| `BASE_URL` | Public base URL for short links | Set from EC2 EIP at configure time |

All secrets are stored as GitHub repo secrets — never in code or git history.

## Operations

### View app logs
```bash
ssh -i deploy_key ec2-user@<EC2_IP>
sudo journalctl -u myshortner03 -f
```

### Restart the app
```bash
sudo systemctl restart myshortner03
```

### Run a new migration
```bash
# Locally: create the revision
alembic revision --autogenerate -m "describe change"
# Commit the new file — Ansible runs `alembic upgrade head` on next deploy
```

### Destroy the stack
Use the **Destroy** workflow in GitHub Actions (dispatched manually). This tears down EC2, EIP, RDS, and all security groups via `terraform destroy`.

## Secret Rotation

| Secret | Consumed by | Restart required |
|--------|-------------|-----------------|
| `DB_PASSWORD` | Ansible `.env` → FastAPI | Yes — redeploy configure stage |
| `SECRET_KEY` | Ansible `.env` → FastAPI | Yes — redeploy configure stage |
