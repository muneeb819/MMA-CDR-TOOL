"""Universal upload ingestion for the CDR scrubber.

The endpoint deliberately does not maintain an extension allow-list. Any file can be
uploaded. Known formats are parsed for text/phone extraction; unknown binaries are
stored as raw evidence and reported as accepted-but-not-extracted.
"""
from __future__ import annotations

import csv
import hashlib
import io
import json
import re
import zipfile
from pathlib import Path
from typing import Any, Iterable

PHONE_RE = re.compile(r"(?<!\d)(?:\+?\d[\d\s().\-]{6,}\d)(?!\d)")


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def extension(name: str) -> str:
    return Path(name or "").suffix.lower().lstrip(".")


def _phones_from_text(text: str) -> list[str]:
    return [m.group(0).strip() for m in PHONE_RE.finditer(text or "")]


def _flatten(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, (dict, list, tuple)):
        return json.dumps(value, ensure_ascii=False, default=str)
    return str(value)


def _rows_from_delimited(data: bytes, delimiter: str | None = None) -> Iterable[str]:
    text = data.decode("utf-8-sig", errors="replace")
    sample = text[:10000]
    if delimiter is None:
        try:
            delimiter = csv.Sniffer().sniff(sample, delimiters=",\t;|^").delimiter
        except csv.Error:
            delimiter = ","
    reader = csv.reader(io.StringIO(text), delimiter=delimiter)
    for row in reader:
        yield " | ".join(row)


def extract_text_rows(filename: str, data: bytes) -> tuple[list[str], str]:
    ext = extension(filename)
    if ext in {"csv", "tsv", "txt", "log", "dat", "psv", "ssv"}:
        delimiter = "\t" if ext == "tsv" else None
        return list(_rows_from_delimited(data, delimiter)), "TEXT_TABLE"
    if ext in {"json", "jsonl", "ndjson"}:
        text = data.decode("utf-8-sig", errors="replace")
        if ext in {"jsonl", "ndjson"}:
            rows = [line for line in text.splitlines() if line.strip()]
        else:
            obj = json.loads(text)
            if isinstance(obj, list):
                rows = [_flatten(x) for x in obj]
            else:
                rows = [_flatten(obj)]
        return rows, "JSON"
    if ext in {"xml", "html", "htm", "xhtml"}:
        from lxml import etree
        root = etree.fromstring(data, parser=etree.XMLParser(recover=True, resolve_entities=False))
        return [" ".join(root.itertext())], "XML"
    if ext in {"xlsx", "xls", "xlsb", "ods"}:
        import pandas as pd
        engine = {"xlsx": "openpyxl", "xls": "xlrd", "xlsb": "pyxlsb"}.get(ext)
        frames = pd.read_excel(io.BytesIO(data), sheet_name=None, engine=engine)
        rows: list[str] = []
        for sheet, frame in frames.items():
            for _, row in frame.fillna("").iterrows():
                rows.append(f"[{sheet}] " + " | ".join(str(x) for x in row.tolist()))
        return rows, "SPREADSHEET"
    if ext == "parquet":
        import pandas as pd
        frame = pd.read_parquet(io.BytesIO(data))
        return [" | ".join(str(x) for x in row) for row in frame.fillna("").itertuples(index=False, name=None)], "PARQUET"
    if ext == "pdf":
        from pypdf import PdfReader
        reader = PdfReader(io.BytesIO(data))
        return [page.extract_text() or "" for page in reader.pages], "PDF"
    if ext in {"docx"}:
        from docx import Document
        doc = Document(io.BytesIO(data))
        return [p.text for p in doc.paragraphs if p.text.strip()], "DOCX"
    if ext in {"zip"}:
        rows: list[str] = []
        with zipfile.ZipFile(io.BytesIO(data)) as z:
            for info in z.infolist():
                if info.is_dir() or info.file_size > 50 * 1024 * 1024:
                    continue
                inner = z.read(info)
                try:
                    inner_rows, _ = extract_text_rows(info.filename, inner)
                    rows.extend(f"[{info.filename}] {r}" for r in inner_rows)
                except Exception:
                    continue
        return rows, "ARCHIVE"
    if ext in {"jpg", "jpeg", "png", "webp", "bmp", "tif", "tiff"}:
        try:
            from PIL import Image
            import pytesseract
            text = pytesseract.image_to_string(Image.open(io.BytesIO(data)))
            return [text], "OCR_IMAGE"
        except Exception as exc:
            return [], f"IMAGE_OCR_UNAVAILABLE:{type(exc).__name__}"

    # Any unknown binary/text file is still accepted. Decode as text when useful.
    text = data.decode("utf-8", errors="ignore")
    if text.strip():
        return [text], "GENERIC_TEXT"
    return [], "RAW_BINARY"


def extract_phones(filename: str, data: bytes) -> dict[str, Any]:
    rows, parser = extract_text_rows(filename, data)
    phones: list[str] = []
    for row in rows:
        phones.extend(_phones_from_text(row))
    return {
        "parser": parser,
        "rows": len(rows),
        "phones": phones,
        "phone_count": len(phones),
        "extractable": bool(rows),
    }
