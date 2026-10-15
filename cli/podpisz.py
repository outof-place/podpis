#!/usr/bin/env python3
"""podpisz: qualified electronic signature with a Szafir (KIR) card, without the Szafir app.

The card's own PKCS#11 driver (CryptoTech Graphite, a universal binary shipped inside
Szafir2.app) talks to the QSCD token. The signature is computed on the card, so the
result is a qualified electronic signature, the same as Szafir's.

Every call is a fresh process that loads the driver anew, so a reader plugged in
after boot is seen without restarting anything. Nothing runs in the background.

Commands (add --json for machine output; exit 0 = ok):
  status                         reader, card, certificate (no PIN)
  miejsce PDF --nad TEKST        where the signature would go (no PIN)
  grafika --out PNG [--imie I] [--wys H]  the exact signature art as a transparent PNG (no PIN)
  pdf PDF [--nad TEKST | --strona N --rect x1 y1 x2 y2] [--out OUT]
                                 PAdES baseline B with a visible stamp, incremental
                                 update (the original stays a byte prefix)
  xml XML [--out OUT]            XAdES-BES enveloped (RSA-SHA256, exc-c14n)
  sprawdz PLIK                   verify a signed PDF or XML

PIN: env PODPIS_PIN, or --pin-stdin, otherwise a native macOS prompt. It is never
written to disk or printed. A wrong PIN is never retried automatically.

Settings live in $PODPIS_HOME (default ~/.local/share/podpis): an optional sygnatura.png
with your handwritten signature (otherwise your name from the certificate is set in a
script font) and an optional config.json, see README.
"""
import argparse
import base64
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

HOME = os.environ.get("PODPIS_HOME") or os.path.expanduser("~/.local/share/podpis")
QSCD_LABEL = "PKI Token 2 (QSCD)"
STAMP_W, STAMP_W_SEAL, STAMP_H_MAX, STAMP_H_MIN = 140.0, 190.0, 48.0, 32.0
GAP_ABOVE = 4.0
DRIVERS = [
    os.path.join(HOME, "libPKCS11Graphite.dylib"),
    "/Applications/Szafir2.app/Contents/app/libPKCS11Graphite.dylib",
    os.path.expanduser("~/Applications/Szafir2.app/Contents/app/libPKCS11Graphite.dylib"),
]
BROWSERS = [
    os.path.join(root, app, "Contents/MacOS", binary)
    for root in ("/Applications", os.path.expanduser("~/Applications"))
    for app, binary in (("Google Chrome.app", "Google Chrome"), ("Chromium.app", "Chromium"),
                        ("Brave Browser.app", "Brave Browser"), ("Microsoft Edge.app", "Microsoft Edge"))
]

NS_DS = "http://www.w3.org/2000/09/xmldsig#"
NS_XADES = "http://uri.etsi.org/01903/v1.3.2#"
EXC_C14N = "http://www.w3.org/2001/10/xml-exc-c14n#"
SHA256 = "http://www.w3.org/2001/04/xmlenc#sha256"
RSA_SHA256 = "http://www.w3.org/2001/04/xmldsig-more#rsa-sha256"
ENVELOPED = "http://www.w3.org/2000/09/xmldsig#enveloped-signature"
PROOF_OF_APPROVAL = "http://uri.etsi.org/01903/v1.2.2#ProofOfApproval"


class Blad(Exception):
    def __init__(self, kod, tekst):
        super().__init__(tekst)
        self.kod, self.tekst = kod, tekst


# ---------------------------------------------------------------- settings

_CONFIG = None


def _config():
    """Optional $PODPIS_HOME/config.json; every key has a default."""
    global _CONFIG
    if _CONFIG is None:
        path = os.path.join(HOME, "config.json")
        try:
            with open(path, encoding="utf-8") as f:
                _CONFIG = json.load(f)
        except FileNotFoundError:
            _CONFIG = {}
        except ValueError as e:
            raise Blad("konfiguracja", f"Błędny {path}: {e}")
    return _CONFIG


def _first_existing(explicit, candidates):
    if explicit:
        return os.path.expanduser(explicit)
    return next((c for c in candidates if os.path.exists(c)), None)


def _driver():
    path = _first_existing(os.environ.get("PODPIS_PKCS11") or _config().get("sterownik"), DRIVERS)
    if not path or not os.path.exists(path):
        raise Blad("brak_sterownika", "Nie widzę sterownika karty (libPKCS11Graphite.dylib). "
                                      "Zainstaluj Szafir2 od KIR albo podaj ścieżkę w PODPIS_PKCS11.")
    return path


def _browser():
    path = _first_existing(os.environ.get("PODPIS_PRZEGLADARKA") or _config().get("przegladarka"), BROWSERS)
    if not path or not os.path.exists(path):
        raise Blad("pieczec", "Do narysowania podpisu potrzebny jest Chrome, Chromium, Brave albo Edge.")
    return path


# ---------------------------------------------------------------- card access

def _token():
    import pkcs11
    lib = pkcs11.lib(_driver())
    slots = lib.get_slots(token_present=False)
    if not slots:
        raise Blad("brak_czytnika", "Nie widzę czytnika. Podłącz czytnik i spróbuj ponownie.")
    label = _config().get("token", QSCD_LABEL)
    for slot in lib.get_slots(token_present=True):
        tok = slot.get_token()
        if tok.label == label:
            return tok
    raise Blad("brak_karty", "Czytnik jest, ale nie widzę karty kwalifikowanej. Włóż kartę.")


def _pin_flags(tok):
    from pkcs11.constants import TokenFlag
    f = tok.flags
    if f & TokenFlag.USER_PIN_LOCKED:
        raise Blad("pin_zablokowany", "PIN karty jest zablokowany. Odblokuj go PUK-iem w aplikacji KIR.")
    return {
        "ostatnia_proba": bool(f & TokenFlag.USER_PIN_FINAL_TRY),
        "malo_prob": bool(f & TokenFlag.USER_PIN_COUNT_LOW),
    }


def _cert_der(session):
    from pkcs11 import Attribute, ObjectClass
    certs = list(session.get_objects({Attribute.CLASS: ObjectClass.CERTIFICATE}))
    if len(certs) != 1:
        raise Blad("certyfikat", f"Spodziewany jeden certyfikat w tokenie QSCD, jest {len(certs)}.")
    return certs[0][Attribute.VALUE], certs[0][Attribute.ID]


def _cert_info(der):
    from asn1crypto import x509
    c = x509.Certificate.load(der)
    subj = c.subject.native
    return {
        "imie_nazwisko": subj.get("common_name"),
        "tytul": subj.get("title"),
        "pesel": (subj.get("serial_number") or "").replace("PNOPL-", ""),
        "wystawca": c.issuer.native.get("common_name"),
        "wazny_do": c["tbs_certificate"]["validity"]["not_after"].native.date().isoformat(),
        "kwalifikowany": "Kwalifikowany" in (c.issuer.native.get("common_name") or ""),
    }


def _get_pin(args):
    if getattr(args, "pin_stdin", False):
        pin = sys.stdin.readline().strip()
    else:
        pin = os.environ.get("PODPIS_PIN", "")
    if not pin:
        script = ('display dialog "PIN do karty z podpisem kwalifikowanym" '
                  'default answer "" with hidden answer with title "Podpis kwalifikowany" '
                  'buttons {"Anuluj", "Podpisz"} default button "Podpisz" cancel button "Anuluj"\n'
                  'text returned of result')
        r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
        if r.returncode != 0:
            raise Blad("anulowano", "Anulowano wpisywanie PIN-u.")
        pin = r.stdout.strip()
    if not re.fullmatch(r"\d{4,12}", pin):
        raise Blad("zly_format_pin", "PIN ma mieć same cyfry (4 do 12).")
    return pin


def _close(session):
    """The CryptoTech driver reports CKR_USER_NOT_LOGGED_IN on C_CloseSession after a
    context-specific login was consumed; the signature is already done by then."""
    try:
        session.close()
    except Exception:
        pass


def _open_signing_session(args):
    import pkcs11
    tok = _token()
    flags = _pin_flags(tok)
    if flags["ostatnia_proba"] and not args.wymus:
        raise Blad("ostatnia_proba", "Karta ma ostatnią próbę PIN-u. Nie zgaduję; użyj --wymus, gdy PIN jest pewny.")
    pin = _get_pin(args)
    try:
        return tok.open(user_pin=pin), pin
    except pkcs11.exceptions.PinIncorrect:
        raise Blad("zly_pin", "Zły PIN. Nie próbuję ponownie.")
    except pkcs11.exceptions.PinLocked:
        raise Blad("pin_zablokowany", "PIN zablokowany.")


def _wait_for_card(seconds):
    """Poll in child processes: a driver loaded in this process may cache the reader list."""
    deadline = time.time() + seconds
    while True:
        r = subprocess.run([sys.executable, "-I", __file__, "status", "--json"],
                           capture_output=True, text=True)
        try:
            if json.loads(r.stdout).get("ok"):
                return
        except ValueError:
            pass
        if time.time() > deadline:
            raise Blad("brak_karty", f"Przez {seconds} s nie pojawiła się karta.")
        time.sleep(1.5)


# ---------------------------------------------------------------- stamp place

def _words(pdf):
    out = subprocess.run(["pdftotext", "-bbox", pdf, "-"], capture_output=True, text=True, check=True).stdout
    pages, cur = [], None
    for line in out.splitlines():
        m = re.search(r'<page width="([\d.]+)" height="([\d.]+)"', line)
        if m:
            cur = {"w": float(m.group(1)), "h": float(m.group(2)), "words": []}
            pages.append(cur)
            continue
        m = re.search(r'xMin="([\d.]+)" yMin="([\d.]+)" xMax="([\d.]+)" yMax="([\d.]+)">(.*)</word>', line)
        if m and cur is not None:
            import html
            cur["words"].append((float(m.group(1)), float(m.group(2)), float(m.group(3)),
                                 float(m.group(4)), html.unescape(m.group(5))))
    return pages


def _find_anchor(pages, text, page_no=None):
    target = text.split()
    hits = []
    for pi, p in enumerate(pages):
        if page_no and pi + 1 != page_no:
            continue
        ws = p["words"]
        for i in range(len(ws) - len(target) + 1):
            if [w[4] for w in ws[i:i + len(target)]] == target:
                seq = ws[i:i + len(target)]
                hits.append((pi, min(w[0] for w in seq), min(w[1] for w in seq),
                             max(w[2] for w in seq), max(w[3] for w in seq)))
    if not hits:
        raise Blad("brak_kotwicy", f"Nie znalazłem tekstu „{text}” w PDF.")
    return hits[-1]  # the last occurrence: signature blocks sit at the end


def _place(pdf, nad, page_no=None, width=None):
    """Stamp rect (PDF coords, bottom-left origin) sitting on the signature line above the anchor.

    The box ends just above the anchor text, so the handwritten signature crosses the rule
    the way ink does; its top stops below the nearest text above.
    """
    from PIL import Image
    width = width or STAMP_W
    pages = _words(pdf)
    pi, x0, y0, x1, _ = _find_anchor(pages, nad, page_no)
    pw, ph = pages[pi]["w"], pages[pi]["h"]
    scale = 2.0
    with tempfile.TemporaryDirectory() as td:
        base = os.path.join(td, "p")
        subprocess.run(["pdftoppm", "-r", str(int(72 * scale)), "-gray", "-png",
                        "-f", str(pi + 1), "-l", str(pi + 1), "-singlefile", pdf, base], check=True)
        img = Image.open(base + ".png").convert("L")
    cx = (x0 + x1) / 2
    left = max(8.0, min(cx - width / 2, pw - 8 - width))
    xa, xb = int(left * scale), int((left + width) * scale)

    def blank(y_pt):
        y = int(y_pt * scale)
        if y < 0 or y >= img.height:
            return False
        return min(img.crop((xa, y, xb, y + 1)).tobytes()) > 235

    bottom_tl = y0 - 1.5
    y, seen_rule, top_limit = y0 - 1.0, False, None
    while y > max(0.0, y0 - 220):
        if blank(y):
            y -= 0.5
            continue
        t = y
        while t > 0 and not blank(t):
            t -= 0.5
        if not seen_rule and y - t <= 3.0 and y0 - y < 16:   # the signature rule: ink may cross it
            seen_rule = True
            y = t
            continue
        top_limit = y
        break
    if top_limit is None:
        top_limit = max(0.0, y)
    avail = bottom_tl - (top_limit + GAP_ABOVE)
    if avail < STAMP_H_MIN:
        raise Blad("brak_miejsca", f"Nad „{nad}” jest tylko {avail:.0f} pt miejsca na podpis.")
    h = min(STAMP_H_MAX, avail)
    top_tl = bottom_tl - h
    rect = [round(left), round(ph - bottom_tl), round(left + width), round(ph - top_tl)]
    return {"strona": pi + 1, "rect": rect}


# ---------------------------------------------------------------- stamp art

INK = "#26307e"     # signature ink
SEAL_INK = "#2c4a72"
SCRIPT_FONTS = '"Snell Roundhand", "Apple Chancery", "Brush Script MT", cursive'

SEAL_SVG = """<svg class="seal" viewBox="0 0 200 200" xmlns="http://www.w3.org/2000/svg">
<defs>
 <path id="top" d="M100,169 A69,69 0 1,1 100,31 A69,69 0 1,1 100,169"/>
 <path id="bot" d="M18,100 A82,82 0 0,0 182,100"/>
</defs>
<g fill="none" stroke="%(c)s">
 <circle cx="100" cy="100" r="95" stroke-width="5.5"/>
 <circle cx="100" cy="100" r="88.5" stroke-width="1.3"/>
 <circle cx="100" cy="100" r="58" stroke-width="2.6"/>
 <circle cx="100" cy="100" r="53.5" stroke-width="0.9"/>
</g>
<g fill="%(c)s" font-family="Georgia, 'Times New Roman', serif" font-weight="700">
 <text font-size="13" letter-spacing="1.05"><textPath href="#top" startOffset="50%%" text-anchor="middle">%(gora)s</textPath></text>
 <text font-size="15" letter-spacing="3"><textPath href="#bot" startOffset="50%%" text-anchor="middle">%(dol)s</textPath></text>
 <text x="45" y="152" font-size="10" text-anchor="middle">★</text>
 <text x="155" y="152" font-size="10" text-anchor="middle">★</text>
 <text x="100" y="91" font-size="15" letter-spacing="1.2" text-anchor="middle">%(s1)s</text>
 <text x="100" y="110" font-size="15" letter-spacing="1.2" text-anchor="middle">%(s2)s</text>
 <rect x="74" y="117" width="52" height="1.2"/>
 <text x="100" y="136" font-size="15" letter-spacing="1.5" text-anchor="middle">%(rok)s</text>
</g></svg>"""

STAMP_HTML = """<!doctype html><html><head><meta charset="utf-8"><style>
@page { size: %(w)spt %(h)spt; margin: 0 }
html, body { margin: 0; width: %(w)spt; height: %(h)spt; overflow: hidden; background: transparent }
* { box-sizing: border-box; -webkit-print-color-adjust: exact; print-color-adjust: exact }
.s { position: relative; width: %(w)spt; height: %(h)spt }
.cap { position: absolute; left: 0; right: 0; top: 0; text-align: center; white-space: nowrap;
       font: 500 4.3pt "Helvetica Neue", Arial, sans-serif; letter-spacing: .22pt; color: #5d6c8c }
.row { position: absolute; left: 0; right: 0; bottom: 0; height: %(rowh)spt;
       display: flex; justify-content: center; align-items: flex-end; gap: 3pt }
.sig { height: 100%%; width: auto; display: block }
.name { flex: 0 1 auto; min-width: 0; white-space: nowrap; line-height: 1.15; padding: 0 2pt 1pt;
        font: 400 %(fs)spt %(script)s; color: %(ink)s }
.seal { flex: none; width: %(seal)spt; height: %(seal)spt; margin-bottom: 1pt;
        transform: rotate(-9deg); opacity: .9 }
</style></head><body><div class="s">
<div class="cap">%(cap)s</div>
<div class="row">%(sig)s%(sealsvg)s</div>
</div><script>
// a typed name shrinks until it fits next to the seal, with room for the swashes
const n = document.querySelector(".name"), seal = document.querySelector(".seal");
if (n) { const room = (n.parentElement.clientWidth - (seal ? seal.getBoundingClientRect().width + 4 : 0)) * 0.9;
  let f = parseFloat(getComputedStyle(n).fontSize);
  while (n.scrollWidth > room && f > 6) { f -= 0.5; n.style.fontSize = f + "px"; } }
</script></body></html>"""


def _signature_png():
    path = _config().get("podpis_png") or os.path.join(HOME, "sygnatura.png")
    path = os.path.expanduser(path)
    return path if os.path.exists(path) else None


def _seal_config():
    c = _config().get("pieczec")
    if not c:
        raise Blad("pieczec", "Pieczęć nie jest ustawiona: dodaj sekcję \"pieczec\" w config.json (README).")
    srodek = (list(c.get("srodek") or []) + ["", ""])[:2]
    return {"gora": c.get("gora", ""), "dol": c.get("dol", ""), "s1": srodek[0], "s2": srodek[1],
            "rok": str(c.get("rok", ""))}


def _stamp_pdf(path, when, w, h, seal, name):
    """Signature art drawn by a headless Chromium: your ink signature (sygnatura.png) or your
    name in a script font, under a small caption, with an optional decorative seal."""
    import html as H
    rowh = round(h - 6.5, 1)
    seal_size = round(min(rowh, 56), 1)
    seal_svg = ""
    if seal:
        c = {k: H.escape(v) for k, v in _seal_config().items()}
        seal_svg = SEAL_SVG % {"c": SEAL_INK, **c}
    png = _signature_png()
    if png:
        sig = f'<img class="sig" src="{H.escape(Path(png).as_uri())}">'
    else:
        sig = f'<div class="name">{H.escape(name or "Podpis")}</div>'
    cap = "Kwalifikowany podpis elektroniczny · " + H.escape(when)
    browser = _browser()
    with tempfile.TemporaryDirectory() as td:
        page = os.path.join(td, "s.html")
        with open(page, "w", encoding="utf-8") as f:
            f.write(STAMP_HTML % {"w": w, "h": h, "rowh": rowh, "seal": seal_size, "cap": cap, "sig": sig,
                                  "sealsvg": seal_svg, "fs": round(rowh * 0.62, 1), "script": SCRIPT_FONTS,
                                  "ink": INK})
        r = subprocess.run([browser, "--headless=new", "--disable-gpu", "--no-first-run",
                            "--allow-file-access-from-files",
                            f"--user-data-dir={td}/prof", "--no-pdf-header-footer",
                            f"--print-to-pdf={path}", Path(page).as_uri()],
                           capture_output=True, text=True, timeout=60)
    if r.returncode != 0 or not os.path.exists(path):
        raise Blad("pieczec", "Nie udało się narysować podpisu: " + (r.stderr or "")[-300:])


def _wants_seal(args):
    # The seal is decoration: the qualified signature alone has the legal effect, so only on request.
    return args.pieczec == "tak"


# ---------------------------------------------------------------- PDF (PAdES)

def cmd_pdf(args):
    if args.out and len(args.plik) > 1:
        raise Blad("out_paczka", "--out działa tylko dla jednego pliku.")
    if _wants_seal(args):
        _seal_config()  # fail before the PIN, not after
    session, pin = _open_signing_session(args)
    try:
        wyniki = [_sign_one_pdf(args, f, session, pin) for f in args.plik]
    finally:
        _close(session)
    return {"ok": all(w["ok"] for w in wyniki), "pliki": wyniki}


def _sign_one_pdf(args, plik, session, pin):
    from pyhanko.pdf_utils.incremental_writer import IncrementalPdfFileWriter
    from pyhanko.pdf_utils.layout import AxisAlignment, InnerScaling, Margins, SimpleBoxLayoutRule
    from pyhanko.sign import fields, signers
    from pyhanko.sign.ades.api import CAdESSignedAttrSpec, GenericCommitment
    from pyhanko.sign.pkcs11 import PKCS11Signer
    from pyhanko.stamp import StaticStampStyle

    seal = _wants_seal(args)
    if args.nad:
        pl = _place(plik, args.nad, args.strona, STAMP_W_SEAL if seal else STAMP_W)
        page, rect = pl["strona"], pl["rect"]
    elif args.strona and args.rect:
        page, rect = args.strona, args.rect
    else:
        raise Blad("brak_miejsca", "Podaj --nad TEKST albo --strona N --rect x1 y1 x2 y2.")
    out = args.out or re.sub(r"\.pdf$", "", plik, flags=re.I) + "-podpisany.pdf"
    der, cid = _cert_der(session)
    info = _cert_info(der)
    # the QSCD key needs a context-specific login before every signature
    signer = PKCS11Signer(session, cert_id=cid, key_id=cid, base_sign_kwargs={"pin": pin})
    x1, y1, x2, y2 = [int(round(v)) for v in rect]
    art = os.path.join(tempfile.mkdtemp(prefix="podpis-"), "pieczec.pdf")
    _stamp_pdf(art, datetime.now().strftime("%d.%m.%Y, %H:%M"), x2 - x1, y2 - y1, seal, info["imie_nazwisko"])
    stamp = StaticStampStyle.from_pdf_file(
        art, border_width=0,
        background_layout=SimpleBoxLayoutRule(
            x_align=AxisAlignment.ALIGN_MID, y_align=AxisAlignment.ALIGN_MID,
            margins=Margins(0, 0, 0, 0), inner_content_scaling=InnerScaling.STRETCH_FILL))
    field = f"Podpis_{info['imie_nazwisko'].replace(' ', '_')}_{datetime.now():%Y%m%d%H%M%S}"
    meta = signers.PdfSignatureMetadata(
        field_name=field, md_algorithm="sha256", subfilter=fields.SigSeedSubFilter.PADES,
        name=info["imie_nazwisko"],
        cades_signed_attr_spec=CAdESSignedAttrSpec(commitment_type=GenericCommitment.PROOF_OF_APPROVAL.asn1),
    )
    with open(plik, "rb") as inf:
        w = IncrementalPdfFileWriter(inf, strict=False)
        fields.append_signature_field(w, fields.SigFieldSpec(sig_field_name=field, on_page=page - 1,
                                                             box=(x1, y1, x2, y2)))
        tmp = out + ".tmp"
        with open(tmp, "wb") as outf:
            signers.PdfSigner(meta, signer=signer, stamp_style=stamp).sign_pdf(w, output=outf)
    os.replace(tmp, out)
    orig = open(plik, "rb").read()
    signed = open(out, "rb").read()
    return {"ok": True, "plik": out, "strona": page, "rect": rect,
            "oryginal_jest_prefiksem": signed.startswith(orig),
            "podpisal": info["imie_nazwisko"], "sha256": hashlib.sha256(signed).hexdigest()}


# ---------------------------------------------------------------- XML (XAdES)

def _rfc4514(name):
    short = {"2.5.4.3": "CN", "2.5.4.6": "C", "2.5.4.10": "O", "2.5.4.11": "OU", "2.5.4.7": "L",
             "2.5.4.8": "ST", "2.5.4.5": "SERIALNUMBER", "2.5.4.97": "2.5.4.97"}
    parts = []
    for rdn in reversed(list(name.chosen)):
        avas = []
        for ava in rdn:
            oid = ava["type"].dotted
            val = ava["value"].native
            if not isinstance(val, str):
                val = str(val)
            val = re.sub(r'([,+"\\<>;=])', r"\\\1", val)
            if val.startswith((" ", "#")):
                val = "\\" + val
            avas.append(f"{short.get(oid, oid)}={val}")
        parts.append("+".join(avas))
    return ",".join(parts)


def _c14n(el):
    from lxml import etree
    return etree.tostring(el, method="c14n", exclusive=True, with_comments=False)


def cmd_xml(args):
    from asn1crypto import x509
    from lxml import etree
    from pkcs11 import Attribute, Mechanism, ObjectClass

    out = args.out or re.sub(r"\.xml$", "", args.plik, flags=re.I) + "-podpisany.xml"
    parser = etree.XMLParser(remove_blank_text=False, resolve_entities=False, no_network=True)
    tree = etree.parse(args.plik, parser)
    root = tree.getroot()
    if root.find(f".//{{{NS_DS}}}Signature") is not None and not args.kolejny:
        raise Blad("juz_podpisany", "Plik ma już podpis XML. Dodaj --kolejny, żeby dołożyć następny.")

    session, pin = _open_signing_session(args)
    try:
        der, cid = _cert_der(session)
        info = _cert_info(der)
        cert = x509.Certificate.load(der)
        key = session.get_key(object_class=ObjectClass.PRIVATE_KEY, id=cid)

        uid = hashlib.sha1(os.urandom(16)).hexdigest()[:12]
        sid, spid, refid = f"Sig-{uid}", f"SignedProperties-{uid}", f"Ref-{uid}"
        D = lambda tag: f"{{{NS_DS}}}{tag}"
        X = lambda tag: f"{{{NS_XADES}}}{tag}"
        E = etree.SubElement

        sig = etree.SubElement(root, D("Signature"), nsmap={"ds": NS_DS}, Id=sid)
        sig.tail = None  # the enveloped transform must leave the document byte-identical
        si = E(sig, D("SignedInfo"))
        E(si, D("CanonicalizationMethod"), Algorithm=EXC_C14N)
        E(si, D("SignatureMethod"), Algorithm=RSA_SHA256)
        r1 = E(si, D("Reference"), Id=refid, URI="")
        tr = E(r1, D("Transforms"))
        E(tr, D("Transform"), Algorithm=ENVELOPED)
        E(tr, D("Transform"), Algorithm=EXC_C14N)
        E(r1, D("DigestMethod"), Algorithm=SHA256)
        dv1 = E(r1, D("DigestValue"))
        r2 = E(si, D("Reference"), Type="http://uri.etsi.org/01903#SignedProperties", URI=f"#{spid}")
        tr2 = E(r2, D("Transforms"))
        E(tr2, D("Transform"), Algorithm=EXC_C14N)
        E(r2, D("DigestMethod"), Algorithm=SHA256)
        dv2 = E(r2, D("DigestValue"))
        sv = E(sig, D("SignatureValue"), Id=f"SignatureValue-{uid}")
        ki = E(sig, D("KeyInfo"))
        E(E(ki, D("X509Data")), D("X509Certificate")).text = base64.b64encode(der).decode()
        obj = E(sig, D("Object"))
        qp = etree.SubElement(obj, X("QualifyingProperties"), nsmap={"xades": NS_XADES}, Target=f"#{sid}")
        sp = E(qp, X("SignedProperties"), Id=spid)
        ssp = E(sp, X("SignedSignatureProperties"))
        E(ssp, X("SigningTime")).text = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        c = E(E(E(ssp, X("SigningCertificate")), X("Cert")), X("CertDigest"))
        E(c, D("DigestMethod"), Algorithm=SHA256)
        E(c, D("DigestValue")).text = base64.b64encode(hashlib.sha256(der).digest()).decode()
        iser = E(c.getparent(), X("IssuerSerial"))
        E(iser, D("X509IssuerName")).text = _rfc4514(cert.issuer)
        E(iser, D("X509SerialNumber")).text = str(cert.serial_number)
        sdop = E(sp, X("SignedDataObjectProperties"))
        dof = E(sdop, X("DataObjectFormat"), ObjectReference=f"#{refid}")
        E(dof, X("MimeType")).text = "text/xml"
        cti = E(sdop, X("CommitmentTypeIndication"))
        E(E(cti, X("CommitmentTypeId")), X("Identifier")).text = PROOF_OF_APPROVAL
        E(cti, X("AllSignedDataObjects"))

        # digest of the document as the enveloped transform sees it
        doc_copy = etree.fromstring(etree.tostring(root))
        for s in doc_copy.findall(f"{{{NS_DS}}}Signature[@Id='{sid}']"):
            doc_copy.remove(s)
        dv1.text = base64.b64encode(hashlib.sha256(_c14n(doc_copy)).digest()).decode()
        dv2.text = base64.b64encode(hashlib.sha256(_c14n(sp)).digest()).decode()
        raw = key.sign(_c14n(si), mechanism=Mechanism.SHA256_RSA_PKCS, pin=pin)
        sv.text = base64.b64encode(raw).decode()
    finally:
        _close(session)
    tmp = out + ".tmp"
    tree.write(tmp, xml_declaration=True, encoding="UTF-8")
    os.replace(tmp, out)
    res = {"ok": True, "plik": out, "podpisal": info["imie_nazwisko"],
           "sha256": hashlib.sha256(open(out, "rb").read()).hexdigest()}
    res["weryfikacja"] = _verify_xml(out)
    return res


def _verify_xml(path):
    """Independent check with xmlsec1 (libxmlsec), signature and both references."""
    from lxml import etree
    root = etree.parse(path).getroot()
    sigs = root.findall(f".//{{{NS_DS}}}Signature")
    if not sigs:
        return {"ok": False, "blad": "brak podpisu"}
    with tempfile.TemporaryDirectory() as td:
        pem = os.path.join(td, "c.pem")
        der = base64.b64decode(sigs[-1].find(f".//{{{NS_DS}}}X509Certificate").text)
        with open(pem, "w") as f:
            f.write("-----BEGIN CERTIFICATE-----\n" + base64.encodebytes(der).decode() + "-----END CERTIFICATE-----\n")
        r = subprocess.run(["xmlsec1", "--verify", "--pubkey-cert-pem", pem, "--lax-key-search",
                            "--id-attr:Id", f"{NS_XADES}:SignedProperties",
                            "--node-xpath", f"//*[local-name()='Signature'][@Id='{sigs[-1].get('Id')}']", path],
                           capture_output=True, text=True)
    return {"ok": r.returncode == 0, "xmlsec1": (r.stderr or r.stdout).strip().splitlines()[-1:]}


# ---------------------------------------------------------------- verify / status

def cmd_sprawdz(args):
    if args.plik.lower().endswith(".xml"):
        return {"ok": True, **{"xml": _verify_xml(args.plik)}}
    from asn1crypto import x509
    from pyhanko.pdf_utils.reader import PdfFileReader
    from pyhanko.sign.validation import validate_pdf_signature
    from pyhanko_certvalidator import ValidationContext
    import logging
    # No trust roots are loaded here (integrity and coverage only), so pyHanko logs a failed
    # path build with a traceback for every signature; that is expected, not news.
    logging.getLogger("pyhanko").setLevel(logging.CRITICAL)
    # The KIR certificate has a postalAddress (2.5.4.16) in its subject, a sequence that
    # asn1crypto 1.5.1 cannot string-prep when it compares names (TypeError: OrderedDict).
    prep = x509.NameTypeAndValue._ldap_string_prep
    x509.NameTypeAndValue._ldap_string_prep = lambda self, s: prep(
        self, s if isinstance(s, str) else json.dumps(s, ensure_ascii=False, sort_keys=True, default=str))
    res = []
    with open(args.plik, "rb") as f:
        r = PdfFileReader(f, strict=False)
        for es in r.embedded_signatures:
            st = validate_pdf_signature(es, ValidationContext(allow_fetching=False))
            res.append({"pole": es.field_name, "podpisal": es.signer_cert.subject.native.get("common_name"),
                        "czas": str(st.signer_reported_dt), "integralnosc": st.intact and st.valid,
                        "obejmuje": st.coverage.name, "zmiany_po": st.modification_level.name if st.modification_level else None})
    return {"ok": all(x["integralnosc"] for x in res) and bool(res), "podpisy": res}


def cmd_status(args):
    tok = _token()
    flags = _pin_flags(tok)
    with tok.open() as s:
        der, _ = _cert_der(s)
    return {"ok": True, "token": tok.label, "numer_karty": tok.serial.decode(errors="replace"),
            "pin": flags, "certyfikat": _cert_info(der)}


def cmd_grafika(args):
    """Transparent PNG of the exact signature art, for previews (no card, no PIN)."""
    seal = _wants_seal(args)
    w = args.szer or (STAMP_W_SEAL if seal else STAMP_W)
    name = args.imie or _config().get("imie")
    with tempfile.TemporaryDirectory() as td:
        _stamp_pdf(os.path.join(td, "s.pdf"), datetime.now().strftime("%d.%m.%Y, %H:%M"), w, args.wys, seal, name)
        base = re.sub(r"\.png$", "", args.out, flags=re.I)
        subprocess.run(["pdftocairo", "-png", "-transp", "-r", str(args.dpi), "-singlefile",
                        os.path.join(td, "s.pdf"), base], check=True)
    return {"ok": True, "plik": base + ".png", "szer": w, "wys": args.wys, "pieczec": seal}


def cmd_miejsce(args):
    width = STAMP_W_SEAL if _wants_seal(args) else STAMP_W
    return {"ok": True, **_place(args.plik, args.nad, args.strona, width)}


def main():
    p = argparse.ArgumentParser(prog="podpisz", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--json", action="store_true")
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--json", action="store_true", default=argparse.SUPPRESS)
    common.add_argument("--czekaj", type=int, default=0, help="czekaj do N s na czytnik i kartę")
    sign = argparse.ArgumentParser(add_help=False)
    sign.add_argument("--pin-stdin", action="store_true")
    sign.add_argument("--wymus", action="store_true", help="pozwól na ostatnią próbę PIN-u")
    sign.add_argument("--out")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status", parents=[common])
    m = sub.add_parser("miejsce", parents=[common])
    m.add_argument("plik"); m.add_argument("--nad", required=True); m.add_argument("--strona", type=int)
    m.add_argument("--pieczec", choices=["tak", "nie"], default="nie")
    pp = sub.add_parser("pdf", parents=[common, sign])
    pp.add_argument("plik", nargs="+"); pp.add_argument("--nad"); pp.add_argument("--strona", type=int)
    pp.add_argument("--rect", type=float, nargs=4)
    pp.add_argument("--pieczec", choices=["tak", "nie"], default="nie",
                    help="ozdobna pieczęć z config.json, tylko na wyraźne życzenie")
    px = sub.add_parser("xml", parents=[common, sign])
    px.add_argument("plik"); px.add_argument("--kolejny", action="store_true")
    pg = sub.add_parser("grafika", parents=[common])
    pg.add_argument("--out", required=True); pg.add_argument("--szer", type=float)
    pg.add_argument("--wys", type=float, default=STAMP_H_MAX); pg.add_argument("--dpi", type=int, default=288)
    pg.add_argument("--imie", help="imię i nazwisko do podglądu, gdy nie ma sygnatura.png")
    pg.add_argument("--pieczec", choices=["tak", "nie"], default="nie")
    ps = sub.add_parser("sprawdz", parents=[common])
    ps.add_argument("plik")
    a = p.parse_args()
    try:
        if getattr(a, "czekaj", 0) and a.cmd in ("status", "pdf", "xml"):
            _wait_for_card(a.czekaj)
        res = {"status": cmd_status, "miejsce": cmd_miejsce, "pdf": cmd_pdf, "grafika": cmd_grafika,
               "xml": cmd_xml, "sprawdz": cmd_sprawdz}[a.cmd](a)
        code = 0 if res.get("ok") else 1
    except Blad as e:
        res, code = {"ok": False, "kod": e.kod, "blad": e.tekst}, 2
    except Exception as e:  # driver and library errors, reported plainly
        res, code = {"ok": False, "kod": "wyjatek", "blad": f"{type(e).__name__}: {e}"}, 3
    if getattr(a, "json", False):
        print(json.dumps(res, ensure_ascii=False))
    else:
        if res.get("ok"):
            for k, v in res.items():
                if k != "ok":
                    print(f"{k}: {v}")
        else:
            print(f"BŁĄD ({res['kod']}): {res['blad']}", file=sys.stderr)
    sys.exit(code)


if __name__ == "__main__":
    main()
