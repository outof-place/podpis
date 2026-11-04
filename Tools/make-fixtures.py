#!/usr/bin/env python3
"""Builds the sample documents in Tests/Fixtures (made-up content, no real data).

Chrome prints the HTML to PDF; pypdf derives the rotated and offset variants that
the geometry tests need. Run it again only when a fixture has to change; name the
files to rebuild only those (`Tools/make-fixtures.py wyglad-blok.pdf`).
"""
import os
import subprocess
import sys
import tempfile

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Tests", "Fixtures")

STYLE = """<style>
@page { size: A4; margin: 22mm 20mm }
body { font: 11pt/1.55 Georgia, serif; color: #111 }
h1 { font: 600 15pt/1.3 "Helvetica Neue", Arial, sans-serif; text-align: center; margin: 0 0 4mm }
.sub { text-align: center; color: #444; margin-bottom: 9mm }
p { margin: 0 0 3.2mm; text-align: justify }
.sig { display: flex; justify-content: space-between; margin-top: 30mm }
.sig div { width: 70mm; text-align: center; font-size: 10.5pt }
.line { border-top: 0.6pt dotted #333; padding-top: 1.5mm }
.tight { margin-top: 2mm }
.brk { break-before: page }
.col { position: relative }
.seal { position: absolute; right: -8mm; bottom: 4mm; width: 34mm; height: 34mm }
.by { margin-top: 12mm; white-space: nowrap }
.by p { text-align: left }
.tab { margin-top: 16mm; border-collapse: collapse; width: 100% }
.tab th, .tab td { border: 0.6pt solid #333; padding: 1.5mm 2mm; text-align: left; font-weight: normal }
</style>"""

LOREM = [
    "Strony zgodnie postanawiają, że Wykonawca przygotuje i wdroży system zgodnie z harmonogramem stanowiącym załącznik nr 1.",
    "Wynagrodzenie płatne jest w terminie 14 dni od dnia doręczenia prawidłowo wystawionej faktury na rachunek wskazany przez Wykonawcę.",
    "Każda ze Stron zobowiązuje się do zachowania w tajemnicy informacji uzyskanych w związku z wykonywaniem Umowy.",
    "Zmiany Umowy wymagają formy pisemnej albo elektronicznej z kwalifikowanym podpisem elektronicznym pod rygorem nieważności.",
    "W sprawach nieuregulowanych Umową zastosowanie mają przepisy Kodeksu cywilnego.",
]


def paragraphs(n, start=1):
    return "".join(f"<p>§ {i}. {LOREM[(i - 1) % len(LOREM)]} {LOREM[i % len(LOREM)]}</p>"
                   for i in range(start, start + n))


SIG_BLOCK = """<div class="sig">
<div><div class="line">Jan Kowalski</div>Zamawiający</div>
<div><div class="line">Jan Kowalski</div>Wykonawca, Prezes Zarządu</div>
</div>"""

DOCS = {
    "umowa-wspolpracy.pdf": f"""<h1>UMOWA O WSPÓŁPRACY nr 7/2026</h1>
<div class="sub">zawarta w Łomży dnia 15 października 2026 r.</div>
{paragraphs(9)}<div class="brk"></div>{paragraphs(5, 10)}{SIG_BLOCK}""",
    "uchwala-zarzadu.pdf": f"""<h1>UCHWAŁA ZARZĄDU nr 3/2026</h1>
<div class="sub">z dnia 15 października 2026 r. w sprawie przyjęcia regulaminu pracy zdalnej</div>
{paragraphs(4)}<div class="sig" style="justify-content:flex-end"><div><div class="line">Jan Kowalski</div>Prezes Zarządu</div></div>""",
    "oswiadczenie.pdf": f"""<h1>OŚWIADCZENIE</h1><div class="sub">o zachowaniu poufności</div>
{paragraphs(3)}<div class="sig" style="justify-content:flex-end"><div><div class="line">podpis</div></div></div>""",
    "protokol-ciasno.pdf": f"""<h1>PROTOKÓŁ ODBIORU</h1><div class="sub">etap 2</div>
{paragraphs(3)}<p style="text-align:right">Odbiór potwierdzam bez zastrzeżeń.</p>
<p class="tight" style="text-align:right">Jan Kowalski</p>""",
}

# For `podpisz wyglad`: the name in the text and in a table's header (a drawn line over it, with
# other cells before it), two signature lines of one person in the block (for the company under a
# drawn line, with a seal printed over its right end, and in person under a typed "By: ____"),
# someone else's line, and an annex bound after the block whose own signature line must stay empty.
SEAL = """<svg class="seal" viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg">
<g fill="none" stroke="#2c4a72"><circle cx="50" cy="50" r="47" stroke-width="3"/><circle cx="50" cy="50" r="33" stroke-width="1"/></g>
<text x="50" y="54" font-size="11" text-anchor="middle" fill="#2c4a72" font-family="Georgia">SEAL</text></svg>"""

DOCS["wyglad-blok.pdf"] = f"""<h1>UMOWA INWESTYCYJNA nr 9/2026</h1>
<div class="sub">zawarta w Łomży dnia 15 października 2026 r.</div>
<p>Stronami Umowy są Przykładowa Spółka sp. z o.o., którą reprezentuje Jan Kowalski, Prezes Zarządu, oraz Anna Nowak.</p>
<p>Jan Kowalski oświadcza, że jest jedynym założycielem Spółki i przystępuje do Umowy także we własnym imieniu.</p>
{paragraphs(6)}<div class="brk"></div>{paragraphs(2, 7)}
<table class="tab"><tr><th>Głos</th><th>Anna Nowak</th><th>Jan Kowalski</th></tr><tr><td>uchwała nr 1</td><td>za</td><td>za</td></tr></table>
<div class="sig">
<div class="col"><div class="line">Jan Kowalski</div>za Spółkę, Prezes Zarządu{SEAL}</div>
<div><div class="line">Anna Nowak</div>Inwestor</div>
</div>
<div class="by"><p>By: ________________________</p><p>Name: Jan Kowalski</p><p>Title: Founder</p></div>
<div class="brk"></div><h1>Załącznik nr 1</h1><div class="sub">wzór oświadczenia założyciela</div>
{paragraphs(1)}<div class="by"><p>By: ________________________</p><p>Name: Jan Kowalski</p></div>"""

# A block with a drawn line and one without (an attorney's signature for the company), both of
# Jan Kowalski, the way the Outofplace partnership agreement has them; his name also in the text
# and above an address, where no art goes.
BLOCK = """<div style="display:flex;margin-top:12mm"><div style="width:38mm;color:#555;font-style:italic">{label}</div>
<div style="width:72mm">{rule}<b>{name}</b>{caps}</div></div>"""
RULE = '<div style="border-top:0.8pt solid #222;margin-top:12mm;padding-top:1mm"></div>'
CAP = '<div style="font-style:italic;color:#555">{}</div>'
SPACE = '<div style="height:12mm"></div>'   # where the line would be, without one

DOCS["wyglad-bez-linii.pdf"] = f"""<h1>UMOWA WSPÓLNIKÓW</h1>
<div class="sub">Jan Kowalski · Anna Nowak · Przykładowa Spółka sp. z o.o.</div>
<p>W sprawach między Spółką a członkiem jej zarządu Spółkę reprezentuje Jan Kowalski, pełnomocnik powołany uchwałą wspólników nr 1/2026.</p>
<p>Adres do doręczeń:</p><p style="text-align:left">Jan Kowalski<br>ul. Polna 1, 00-001 Warszawa</p>
{paragraphs(2)}
{BLOCK.format(label='Wspólnik', rule=RULE, name='Jan Kowalski', caps=CAP.format('kwalifikowany podpis elektroniczny'))}
{BLOCK.format(label='Wspólnik', rule=RULE, name='Anna Nowak', caps=CAP.format('kwalifikowany podpis elektroniczny'))}
{BLOCK.format(label='Spółka<br>(art. 210 § 1 KSH)', rule=SPACE, name='Jan Kowalski',
              caps=CAP.format('pełnomocnik z uchwały nr 1/2026') + CAP.format('kwalifikowany podpis elektroniczny'))}"""

XML = """<?xml version="1.0" encoding="UTF-8"?>
<Deklaracja xmlns="http://example.com/deklaracja/2026">
  <Naglowek>
    <KodFormularza>ZGL-1</KodFormularza>
    <DataWypelnienia>2026-10-15</DataWypelnienia>
  </Naglowek>
  <Podmiot>
    <Nazwa>PRZYKŁADOWA SPÓŁKA SP. Z O.O.</Nazwa>
    <Miejscowosc>Warszawa</Miejscowosc>
    <Reprezentant rola="Prezes Zarządu">Jan Kowalski</Reprezentant>
  </Podmiot>
  <Tresc>Zgłoszenie zmiany danych kontaktowych spółki.</Tresc>
</Deklaracja>
"""


def html_to_pdf(html, out):
    with tempfile.TemporaryDirectory() as td:
        page = os.path.join(td, "d.html")
        with open(page, "w") as f:
            f.write(f'<!doctype html><html lang="pl"><head><meta charset="utf-8">{STYLE}</head><body>{html}</body></html>')
        subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--no-first-run", f"--user-data-dir={td}/p",
                        "--no-pdf-header-footer", f"--print-to-pdf={out}", "file://" + page],
                       check=True, capture_output=True)


def variants():
    """Rotated pages and a media box that does not start at 0,0, for the geometry tests."""
    from pypdf import PdfReader, PdfWriter
    from pypdf.generic import RectangleObject
    src = os.path.join(OUT, "uchwala-zarzadu.pdf")
    for rot in (90, 180, 270):
        w = PdfWriter()
        w.append(PdfReader(src))
        page = w.pages[0]
        mb = page.mediabox
        page.mediabox = RectangleObject([float(mb.left) + 30, float(mb.bottom) + 40, float(mb.right) + 30, float(mb.top) + 40])
        # shift the content with the box so the page still shows the same thing
        page.add_transformation((1, 0, 0, 1, 30, 40))
        page.rotation = rot
        with open(os.path.join(OUT, f"uchwala-obrot-{rot}.pdf"), "wb") as f:
            w.write(f)


def main():
    os.makedirs(OUT, exist_ok=True)
    only = set(sys.argv[1:])
    for name, html in DOCS.items():
        if not only or name in only:
            html_to_pdf(html, os.path.join(OUT, name))
    if not only:
        with open(os.path.join(OUT, "zgloszenie.xml"), "w", encoding="utf-8") as f:
            f.write(XML)
        variants()
    print("\n".join(sorted(os.listdir(OUT))))


if __name__ == "__main__":
    sys.exit(main())
