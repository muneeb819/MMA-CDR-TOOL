"""MMA-CDR TOOL file logging. Every API call + every UI click lands in logs/mma-cdr-api.log."""
from __future__ import annotations
import json
import logging
from logging.handlers import RotatingFileHandler
from pathlib import Path

LOG_DIR = Path(__file__).resolve().parent.parent / "logs"
LOG_FILE = LOG_DIR / "mma-cdr-api.log"
_configured = False


def get_logger() -> logging.Logger:
    global _configured
    logger = logging.getLogger("mma_cdr")
    if _configured:
        return logger
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    logger.setLevel(logging.INFO)
    handler = RotatingFileHandler(str(LOG_FILE), maxBytes=5 * 1024 * 1024, backupCount=5, encoding="utf-8")
    handler.setFormatter(logging.Formatter("%(asctime)s | %(levelname)s | %(message)s"))
    logger.addHandler(handler)
    # Also keep console output (uvicorn captures it).
    console = logging.StreamHandler()
    console.setFormatter(logging.Formatter("%(asctime)s | %(levelname)s | %(message)s"))
    logger.addHandler(console)
    logger.propagate = False
    _configured = True
    return logger


def log_event(action: str, detail: dict | None = None, result: dict | str | None = None) -> None:
    logger = get_logger()
    try:
        d = json.dumps(detail or {}, ensure_ascii=False, default=str)[:2000]
        r = result if isinstance(result, str) else json.dumps(result or {}, ensure_ascii=False, default=str)[:2000]
    except Exception:
        d, r = "{}", "{}"
    logger.info("action=%s detail=%s result=%s", action, d, r)
