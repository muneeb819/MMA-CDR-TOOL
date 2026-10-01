"""Re-create the small, non-production binary upload fixtures deterministically.

Run with the project's API requirements installed:
    python tests/fixtures/generate_fixtures.py
"""
from __future__ import annotations

import io
import zipfile
from pathlib import Path

from docx import Document
from openpyxl import Workbook
from PIL import Image, ImageDraw
from pypdf import PdfWriter
from pypdf.generic import DecodedStreamObject, DictionaryObject, NameObject

FIXTURES = Path(__file__).resolve().parent
ROWS = [
    ("Synthetic Test User 1", "+14155550132"),
    ("Synthetic Test User 2", "+12125550111"),
]


def make_xlsx() -> None:
    workbook = Workbook()
    sheet = workbook.active
    sheet.title = "Test Leads"
    sheet.append(["name", "phone"])
    for row in ROWS:
        sheet.append(row)
    workbook.save(FIXTURES / "phones.xlsx")


def make_parquet() -> None:
    import pandas as pd

    pd.DataFrame(ROWS, columns=["name", "phone"]).to_parquet(FIXTURES / "phones.parquet", index=False)


def make_pdf() -> None:
    writer = PdfWriter()
    page = writer.add_blank_page(width=612, height=792)
    font = DictionaryObject({
        NameObject("/Type"): NameObject("/Font"),
        NameObject("/Subtype"): NameObject("/Type1"),
        NameObject("/BaseFont"): NameObject("/Helvetica"),
    })
    resources = DictionaryObject({NameObject("/Font"): DictionaryObject({NameObject("/F1"): writer._add_object(font)})})
    page[NameObject("/Resources")] = resources
    stream = DecodedStreamObject()
    stream.set_data(b"BT /F1 12 Tf 72 720 Td (Phone +1 \\(415\\) 555-0132) Tj ET")
    page[NameObject("/Contents")] = writer._add_object(stream)
    with (FIXTURES / "phones.pdf").open("wb") as output:
        writer.write(output)


def make_docx() -> None:
    document = Document()
    document.add_paragraph("Synthetic Test User 1 phone +1 (415) 555-0132")
    document.add_paragraph("Synthetic Test User 2 phone +1 212 555 0111")
    document.save(FIXTURES / "phones.docx")


def make_nested_zip() -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("nested/deep.csv", "name,phone\nNested Synthetic,+1 310 555 0123\n")
    return buffer.getvalue()


def make_zip() -> None:
    with zipfile.ZipFile(FIXTURES / "phones.zip", "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("nested/phones.csv", "name,phone\nArchived Synthetic,+1 415 555 0132\n")
        archive.writestr("notes.txt", "Archive note; callback +1 212 555 0111\n")
        archive.writestr("ignored.bin", b"\x00\x01\x02\x03")
        archive.writestr("nested/more.zip", make_nested_zip())

    with zipfile.ZipFile(FIXTURES / "path-traversal.zip", "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("../../outside.csv", "name,phone\nTraversal Synthetic,+1 415 555 0132\n")


def make_image() -> None:
    image = Image.new("RGB", (900, 180), "white")
    ImageDraw.Draw(image).text((20, 60), "Synthetic Test phone +1 (415) 555-0132", fill="black")
    image.save(FIXTURES / "phone-image.png", format="PNG")


def main() -> None:
    make_xlsx()
    make_parquet()
    make_pdf()
    make_docx()
    make_zip()
    make_image()
    (FIXTURES / "corrupt.zip").write_bytes(b"not a valid zip archive")
    (FIXTURES / "corrupt.xlsx").write_bytes(b"not an xlsx workbook")
    (FIXTURES / "binary.custom").write_bytes(b"\x00\x01\x02\xff\x00")
    print("Generated small deterministic MMA-CDR ingestion fixtures.")


if __name__ == "__main__":
    main()
