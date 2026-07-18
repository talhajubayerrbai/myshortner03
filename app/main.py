import os
import string
import random
from fastapi import FastAPI, HTTPException, Depends
from fastapi.responses import RedirectResponse
from pydantic import BaseModel, HttpUrl
from sqlalchemy.orm import Session

from app.database import get_db, engine
from app import models

models.Base.metadata.create_all(bind=engine)

app = FastAPI(title="myshortner03 URL Shortener", version="1.0.0")

ALPHABET = string.ascii_letters + string.digits
CODE_LENGTH = 7
BASE_URL = os.getenv("BASE_URL", "http://localhost:8000")


def generate_code() -> str:
    return "".join(random.choices(ALPHABET, k=CODE_LENGTH))


class ShortenRequest(BaseModel):
    url: HttpUrl


class ShortenResponse(BaseModel):
    short_url: str
    code: str
    original_url: str


@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/shorten", response_model=ShortenResponse)
def shorten(request: ShortenRequest, db: Session = Depends(get_db)):
    original = str(request.url)

    # Check if URL already exists
    existing = db.query(models.Link).filter(models.Link.original_url == original).first()
    if existing:
        return ShortenResponse(
            short_url=f"{BASE_URL}/{existing.code}",
            code=existing.code,
            original_url=existing.original_url,
        )

    # Generate a unique code
    for _ in range(10):
        code = generate_code()
        if not db.query(models.Link).filter(models.Link.code == code).first():
            break
    else:
        raise HTTPException(status_code=500, detail="Could not generate unique code")

    link = models.Link(code=code, original_url=original)
    db.add(link)
    db.commit()
    db.refresh(link)

    return ShortenResponse(
        short_url=f"{BASE_URL}/{link.code}",
        code=link.code,
        original_url=link.original_url,
    )


@app.get("/{code}")
def redirect(code: str, db: Session = Depends(get_db)):
    link = db.query(models.Link).filter(models.Link.code == code).first()
    if not link:
        raise HTTPException(status_code=404, detail="Short URL not found")
    link.hits += 1
    db.commit()
    return RedirectResponse(url=link.original_url, status_code=302)
