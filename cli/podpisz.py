#!/usr/bin/env python3
"""podpisz: qualified electronic signature with a Szafir (KIR) card, without the Szafir app.

The card's own PKCS#11 driver (CryptoTech Graphite, a universal binary shipped inside
Szafir2.app) talks to the QSCD token. The signature is computed on the card, so the
result is a qualified electronic signature, the same as Szafir's.

mSzafir, KIR's remote (cloud) qualified signature, goes through the PKCS#11 driver of
CloudSigner (CryptoTech, libCloudSignerP11.dylib) instead: "sterownik": "mszafir" in
config.json. There is no PIN: CloudSigner asks for the code from the mSzafir phone app
and the signature is approved on the phone.

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
  wyglad PDF... [--nad TEKST] [--out-dir DIR] [--bez-cofania] [--podpisz]
                                 the signature art on every signature line of TEKST, for a
                                 signature made with another tool afterwards (no card, no PIN);
                                 with --podpisz the token signs it right away, invisibly

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
import shutil
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
CARD_DRIVERS = [
    os.path.join(HOME, "libPKCS11Graphite.dylib"),
    "/Applications/Szafir2.app/Contents/app/libPKCS11Graphite.dylib",
    os.path.expanduser("~/Applications/Szafir2.app/Contents/app/libPKCS11Graphite.dylib"),
]
# mSzafir: this driver talks to CloudSigner's RepoServer, which runs while the CloudSigner app does
CLOUDSIGNER_DRIVER = "/Applications/CloudSigner.app/Contents/Frameworks/libCloudSignerP11.dylib"
DRIVERS = CARD_DRIVERS + [CLOUDSIGNER_DRIVER]
CLOUDSIGNER_START_S = 30
PODPISANY_SUFFIX = "-podpisany"
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
    """The PKCS#11 driver: a path, "mszafir" (CloudSigner) or "karta" (Szafir2's), else the first found."""
    explicit = os.environ.get("PODPIS_PKCS11") or _config().get("sterownik")
    if explicit == "mszafir":
        explicit = CLOUDSIGNER_DRIVER
    path = _first_existing(None if explicit == "karta" else explicit,
                           CARD_DRIVERS if explicit == "karta" else DRIVERS)
    if path and _is_cloudsigner(path) and not os.path.exists(path):
        raise Blad("brak_sterownika", "Nie widzę CloudSignera (mSzafir). Zainstaluj go od KIR: "
                                      "elektronicznypodpis.pl, Aplikacje i sterowniki.")
    if not path or not os.path.exists(path):
        raise Blad("brak_sterownika", "Nie widzę sterownika karty (libPKCS11Graphite.dylib) ani CloudSignera "
                                      "(mSzafir). Zainstaluj Szafir2 albo CloudSigner od KIR, "
                                      "albo podaj ścieżkę w PODPIS_PKCS11.")
    return path


def _is_cloudsigner(path):
    return os.path.basename(path).startswith("libCloudSignerP11")


def _start_cloudsigner(driver):
    """mSzafir's driver needs CloudSigner running: its RepoServer serves the virtual card, and its
    window asks for the code from the phone. Start it when it is not running: in the front, because
    after a start in the background (open -g) its window did not show the signing request."""
    def up():
        return all(subprocess.run(["/usr/bin/pgrep", "-x", "-U", str(os.getuid()), name],
                                  capture_output=True).returncode == 0
                   for name in ("CloudSignerNg", "RepoServer"))
    if up():
        return
    app = driver.split("/Contents/")[0]
    subprocess.run(["/usr/bin/open", "-a", app], capture_output=True)
    deadline = time.time() + CLOUDSIGNER_START_S
    while not up():
        if time.time() > deadline:
            raise Blad("cloudsigner", f"CloudSigner (mSzafir) nie wystartował w {CLOUDSIGNER_START_S} s. "
                                      "Otwórz go z folderu Aplikacje.")
        time.sleep(0.5)
    time.sleep(2)   # RepoServer loads the card list after it starts


def _browser():
    path = _first_existing(os.environ.get("PODPIS_PRZEGLADARKA") or _config().get("przegladarka"), BROWSERS)
    if not path or not os.path.exists(path):
        raise Blad("pieczec", "Do narysowania podpisu potrzebny jest Chrome, Chromium, Brave albo Edge.")
    return path


# ---------------------------------------------------------------- card access

def _token():
    import pkcs11
    driver = _driver()
    if _is_cloudsigner(driver):
        _start_cloudsigner(driver)
        tokens = [s.get_token() for s in pkcs11.lib(driver).get_slots(token_present=True)]
        label = _config().get("token")
        if label:
            tokens = [t for t in tokens if t.label == label]
        if len(tokens) == 1:
            return tokens[0]
        if tokens:
            raise Blad("token", "CloudSigner ma kilka kart: " + ", ".join(t.label for t in tokens)
                       + ". Wpisz właściwą jako \"token\" w config.json.")
        raise Blad("brak_karty", "CloudSigner nie ma karty mSzafir" + (f" „{label}”" if label else "")
                   + ". Dodaj ją: ikona CloudSigner na pasku menu, Certyfikaty, Dodaj nową kartę, "
                     "i kod z aplikacji mSzafir na telefonie (Generuj kod).")
    lib = pkcs11.lib(driver)
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
    if len(certs) > 1:
        # mSzafir's token also carries KIR's root CA and a TLS certificate: the signer's has the private key
        keys = {k[Attribute.ID] for k in session.get_objects({Attribute.CLASS: ObjectClass.PRIVATE_KEY})}
        certs = [c for c in certs if c[Attribute.ID] in keys]
    if len(certs) != 1:
        raise Blad("certyfikat", f"Spodziewany jeden certyfikat z kluczem w tokenie, jest {len(certs)}.")
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
    """A session that can sign, and the PIN for the key's context-specific login (None for mSzafir)."""
    import pkcs11
    from pkcs11.constants import TokenFlag
    tok = _token()
    if _is_cloudsigner(_driver()):
        # no PIN: CloudSigner itself asks for the phone's code and the phone approves the signature
        if not tok.flags & TokenFlag.LOGIN_REQUIRED:
            return tok.open(), None
        return tok.open(user_pin=pkcs11.PROTECTED_AUTH), None
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
    # Chrome may exit non-zero after the PDF is written ("Teardown watchdog expired"): the file decides
    if not _whole_pdf(path):
        raise Blad("pieczec", "Nie udało się narysować podpisu: " + (r.stderr or "")[-300:])


def _whole_pdf(path):
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError:
        return False
    return data.startswith(b"%PDF-") and b"%%EOF" in data[-1024:]


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
        signer, name = _signer(session, pin)
        wyniki = [_sign_one_pdf(args, f, signer, name) for f in args.plik]
    finally:
        _close(session)
    return {"ok": all(w["ok"] for w in wyniki), "pliki": wyniki}


def _signer(session, pin):
    """pyHanko's signer over the token's key, and the signer's name from the certificate."""
    from pyhanko.sign.pkcs11 import PKCS11Signer
    der, cid = _cert_der(session)
    # the QSCD key needs a context-specific login before every signature; mSzafir's has no PIN
    signer = PKCS11Signer(session, cert_id=cid, key_id=cid, base_sign_kwargs={"pin": pin} if pin else None)
    return signer, _cert_info(der)["imie_nazwisko"]


def _show_cloudsigner(signer):
    """mSzafir: CloudSigner's window asks for the phone's code and lists the request, but it opens
    behind other windows, and a droplet run has no terminal to look at. Bring CloudSigner to the
    front once the signature is under way. A card or a test signer: nothing to show."""
    from pyhanko.sign.pkcs11 import PKCS11Signer
    if not isinstance(signer, PKCS11Signer) or not _is_cloudsigner(_driver()):
        return
    app = _driver().split("/Contents/")[0]
    subprocess.Popen(["/bin/sh", "-c", 'sleep 1.5; exec /usr/bin/open -a "$0"', app], stdin=subprocess.DEVNULL,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


def _sign_pdf(src, out, signer, name, page=None, rect=None, seal=False):
    """PAdES baseline B over `src` into `out` as an incremental update: visible in `rect` on `page`,
    or invisible without a rect. `out` appears only once the signature is done."""
    from pyhanko.pdf_utils.incremental_writer import IncrementalPdfFileWriter
    from pyhanko.pdf_utils.layout import AxisAlignment, InnerScaling, Margins, SimpleBoxLayoutRule
    from pyhanko.sign import fields, signers
    from pyhanko.sign.ades.api import CAdESSignedAttrSpec, GenericCommitment
    from pyhanko.stamp import StaticStampStyle

    field = f"Podpis_{name.replace(' ', '_')}_{datetime.now():%Y%m%d%H%M%S}"
    meta = signers.PdfSignatureMetadata(
        field_name=field, md_algorithm="sha256", subfilter=fields.SigSeedSubFilter.PADES,
        name=name,
        cades_signed_attr_spec=CAdESSignedAttrSpec(commitment_type=GenericCommitment.PROOF_OF_APPROVAL.asn1),
    )
    stamp = None
    with open(src, "rb") as inf:
        w = IncrementalPdfFileWriter(inf, strict=False)
        if rect:
            x1, y1, x2, y2 = [int(round(v)) for v in rect]
            art = os.path.join(tempfile.mkdtemp(prefix="podpis-"), "pieczec.pdf")
            _stamp_pdf(art, datetime.now().strftime("%d.%m.%Y, %H:%M"), x2 - x1, y2 - y1, seal, name)
            stamp = StaticStampStyle.from_pdf_file(
                art, border_width=0,
                background_layout=SimpleBoxLayoutRule(
                    x_align=AxisAlignment.ALIGN_MID, y_align=AxisAlignment.ALIGN_MID,
                    margins=Margins(0, 0, 0, 0), inner_content_scaling=InnerScaling.STRETCH_FILL))
            fields.append_signature_field(w, fields.SigFieldSpec(sig_field_name=field, on_page=page - 1,
                                                                 box=(x1, y1, x2, y2)))
        tmp = out + ".tmp"
        try:
            with open(tmp, "wb") as outf:
                signers.PdfSigner(meta, signer=signer, stamp_style=stamp).sign_pdf(w, output=outf)
        except BaseException:   # refused on the phone, card pulled: no half-written file left behind
            if os.path.exists(tmp):
                os.remove(tmp)
            raise
    os.replace(tmp, out)


def _sign_one_pdf(args, plik, signer, name):
    seal = _wants_seal(args)
    if args.nad:
        pl = _place(plik, args.nad, args.strona, STAMP_W_SEAL if seal else STAMP_W)
        page, rect = pl["strona"], pl["rect"]
    elif args.strona and args.rect:
        page, rect = args.strona, args.rect
    else:
        raise Blad("brak_miejsca", "Podaj --nad TEKST albo --strona N --rect x1 y1 x2 y2.")
    out = args.out or re.sub(r"\.pdf$", "", plik, flags=re.I) + PODPISANY_SUFFIX + ".pdf"
    _show_cloudsigner(signer)
    _sign_pdf(plik, out, signer, name, page, rect, seal)
    orig = open(plik, "rb").read()
    signed = open(out, "rb").read()
    return {"ok": True, "plik": out, "strona": page, "rect": rect,
            "oryginal_jest_prefiksem": signed.startswith(orig),
            "podpisal": name, "sha256": hashlib.sha256(signed).hexdigest()}


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
    if not shutil.which("xmlsec1"):  # the signature is checked before it is written; fail before the PIN
        raise Blad("brak_xmlsec1", "Do podpisu XML potrzebny jest xmlsec1: brew install libxmlsec1.")

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

def _pyhanko_quiet():
    """pyHanko set up for checking signatures without trust roots (sprawdz, wyglad)."""
    import logging
    from asn1crypto import x509
    # No trust roots are loaded here (integrity and coverage only), so pyHanko logs a failed
    # path build with a traceback for every signature; that is expected, not news.
    logging.getLogger("pyhanko").setLevel(logging.CRITICAL)
    if getattr(x509.NameTypeAndValue, "_podpis_prep", False):
        return
    # The KIR certificate has a postalAddress (2.5.4.16) in its subject, a sequence that
    # asn1crypto 1.5.1 cannot string-prep when it compares names (TypeError: OrderedDict).
    prep = x509.NameTypeAndValue._ldap_string_prep
    x509.NameTypeAndValue._ldap_string_prep = lambda self, s: prep(
        self, s if isinstance(s, str) else json.dumps(s, ensure_ascii=False, sort_keys=True, default=str))
    x509.NameTypeAndValue._podpis_prep = True


def cmd_sprawdz(args):
    if args.plik.lower().endswith(".xml"):
        return {"ok": True, **{"xml": _verify_xml(args.plik)}}
    from pyhanko.pdf_utils.reader import PdfFileReader
    from pyhanko.sign.validation import validate_pdf_signature
    from pyhanko_certvalidator import ValidationContext
    _pyhanko_quiet()
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
    mszafir = _is_cloudsigner(_driver())
    # mSzafir has no PIN on this side: no tries to run out of (Podpis.app reads these flags)
    flags = {"ostatnia_proba": False, "malo_prob": False} if mszafir else _pin_flags(tok)
    with tok.open() as s:
        der, _ = _cert_der(s)
    return {"ok": True, "sterownik": "mszafir" if mszafir else "karta", "token": tok.label,
            "numer_karty": tok.serial.decode(errors="replace"), "pin": flags, "certyfikat": _cert_info(der)}


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


# ---------------------------------------------------------------- art for another tool's signature (wyglad)
#
# Some signers use a tool that makes only an invisible signature (a field with an empty /Rect).
# `wyglad` puts the same art `pdf` draws on every signature line of that person BEFORE they sign,
# as a locked /Stamp annotation in an incremental update, so their signature covers it. Nothing is
# added after the last signature, earlier signatures keep their bytes and the page content stays.

WYGLAD_SUFFIX = "-do-podpisu"
RULE_REACH = 30.0     # a signature line sits at most this far above the name
RULE_MIN = 60.0       # and is at least this long
OVERHANG = 10.0       # the art may reach past either end of the line by this much
SCALE_MIN = 0.6       # the art may shrink this far to keep off a picture (a seal)
PICTURE_CLEAR = 0.005  # share of picture pixels under the art that still counts as clear
STAMP_FLAGS = 4 | 64 | 128 | 512   # Print, ReadOnly, Locked, LockedContents
STAMP_NM = "podpis-wyglad-"
CAPTION_LINES = 3      # a block without a line: the caption is in the first lines under the name
CAPTION_WORDS = 8      # and short ("kwalifikowany podpis elektroniczny", "(podpis)")
_RULE_TEXT = re.compile(r"^(.*?)(_{5,}|[.…]{8,})$")
_TRIM = ".,;:()[]\"'„”«»"


def _fold(s):
    """Upper case without diacritics: 'Łukasz Żółć' -> 'LUKASZ ZOLC'."""
    import unicodedata
    s = (s or "").replace("ł", "l").replace("Ł", "L")
    return "".join(c for c in unicodedata.normalize("NFD", s) if not unicodedata.combining(c)).upper()


def _same_line(a, b):
    """Two boxes (x0, y0, x1, y1, ...) on one text line."""
    return min(a[3], b[3]) - max(a[1], b[1]) >= 0.5 * min(a[3] - a[1], b[3] - b[1])


def _name_hits(words, nad):
    """Every place the name is written, punctuation and case aside ('Bogdan,' and 'BOGDAN' count)."""
    want = [_fold(w) for w in nad.split()]
    for i in range(len(words) - len(want) + 1):
        seq = words[i:i + len(want)]
        if [_fold(w[4].strip(_TRIM)) for w in seq] == want and all(_same_line(seq[0], w) for w in seq):
            yield (min(w[0] for w in seq), min(w[1] for w in seq), max(w[2] for w in seq), max(w[3] for w in seq))


def _text_rule(words, name):
    """A line typed as underscores or dots just above the name: (left, right, y, word) or None."""
    x0, y0, x1, _ = name
    best = None
    for w in words:
        m = _RULE_TEXT.match(w[4])
        if not m or not (y0 - RULE_REACH <= w[3] <= y0 + 1):
            continue
        if min(x1, w[2]) - max(x0, w[0]) < min(20.0, (x1 - x0) / 2):
            continue
        if best is None or w[3] > best[1][3]:
            best = (m, w)
    if best is None:
        return None
    m, w = best
    # "By:______" read as one word keeps its label off the line
    left = w[0] + (w[2] - w[0]) * len(m.group(1)) / len(w[4])
    return (left, w[2], w[3] - 2.0, w) if w[2] - left >= RULE_MIN else None


def _drawn_rule(img, s, name):
    """A drawn line, at most 3 pt thick and at least RULE_MIN long, just above the name, or None."""
    x0, y0, x1, _ = name
    px, W, H = img.load(), img.width, img.height
    xa = int(x0 * s)
    xb = max(xa + 1, int(x1 * s))

    def ink(y):
        return 0 <= y < H and any(px[x, y] < 236 for x in range(xa, xb))

    def dark(y):
        return sum(1 for x in range(xa, xb) if px[x, y] < 160) if 0 <= y < H else 0

    y, stop = int((y0 - 1) * s), max(0, int((y0 - RULE_REACH) * s))
    while y > stop and not ink(y):
        y -= 1
    if y <= stop:
        return None
    t = y
    while t > 0 and ink(t):
        t -= 1
    if (y - t) / s > 3.0:   # the first ink above the name is text or a picture, not a line
        return None
    row = max(range(t + 1, y + 1), key=dark)
    if dark(row) < 0.25 * (xb - xa):   # a dotted line is about a third ink
        return None
    gap = int(3 * s)   # dotted lines

    def reach(x, step):
        last, miss = x, 0
        while 0 <= x < W and miss <= gap:
            if any(px[x, r] < 160 for r in (row - 1, row, row + 1) if 0 <= r < H):
                last, miss = x, 0
            else:
                miss += 1
            x += step
        return last

    mid = (xa + xb) // 2
    left, right = reach(mid, -1) / s, reach(mid, 1) / s
    return (left, right, row / s, None) if right - left >= RULE_MIN else None


def _caption_rule(words, name):
    """A signature block without a line: the name alone in its column, and right under it, starting
    where it starts, a short caption that says it is a signature ("kwalifikowany podpis elektroniczny",
    maybe under a role: "pełnomocnik z uchwały nr 13/2026"). The art goes where the line would be:
    (left, right, y, None), or None. A name in the text has words beside it; an address under a
    name has no caption."""
    x0, y0, x1, y1 = name
    h = y1 - y0
    if any(w[2] > x0 - 30.0 and w[0] < x1 + 40.0 for w in words
           if _same_line(w, name) and not (w[0] >= x0 - 0.5 and w[2] <= x1 + 0.5)):
        return None
    lines = []
    for w in sorted((w for w in words if w[1] > y1 - 0.5 * h and w[1] < y1 + CAPTION_LINES * 2.5 * h),
                    key=lambda w: (w[1], w[0])):
        for ln in lines:
            if _same_line(ln[0], w):
                ln.append(w)
                break
        else:
            lines.append([w])
    right, bottom, caption = x1, y1, False
    for ln in sorted(lines, key=lambda ln: min(w[1] for w in ln))[:CAPTION_LINES]:
        col = [w for w in ln if w[0] >= x0 - 3.0]   # a label column to the left is not the block's
        if not col or abs(min(w[0] for w in col) - x0) > 3.0 or min(w[1] for w in col) - bottom > h:
            break
        if len(col) <= CAPTION_WORDS and "PODPIS" in _fold(" ".join(w[4] for w in col)):
            caption = True
        right, bottom = max(right, max(w[2] for w in col)), max(w[3] for w in col)
    if not caption:
        return None
    return (x0, max(right, x0 + RULE_MIN), y0 - 2.0, None)


def _art_box(words, annots, pictures, s, name, rule, pw):
    """Where the art goes on one signature line: (left, top, width, height, scale), top-left points.

    On the line first. Like _place, the box ends just above the name, so the signature crosses the
    line the way ink does, and its top stays clear of the nearest text or annotation above. Along
    the line it keeps off labels ("By:"); of the free positions it takes the tallest, then the one
    nearest the middle of the line.

    A picture over the line (a company seal printed next to the name) is not covered: when every
    full-size position would lie on it, the same art is drawn smaller (down to SCALE_MIN) where it
    clears the picture. Only when even that fails does it go full size over the fewest picture
    pixels; the Multiply blend then lets the picture show through, as under ink.

    When the line has no room above it (the previous signer's date line sits right over it), the
    art goes beside it, to the right of the name's lines, ending 13 pt below the name, lined up
    with another signature's art on the page when there is one: where Podpis users drag theirs.
    """
    rx0, rx1, ry, rule_word = rule
    x0, y0, x1, y1 = name
    mid = (rx0 + rx1) / 2
    right_edge = min(pw - 8.0, max((w[2] for w in words), default=pw - 8.0))
    others = [w for w in words if w is not rule_word] + annots

    def picture_share(left, top, right, bottom):
        b = min(bottom, ry - 2.0)   # the line itself is no picture
        if b <= top + 1:
            return 0.0
        crop = pictures.crop((int(left * s), int(top * s), int(right * s), int(b * s)))
        return sum(crop.histogram()[:200]) / max(1, crop.width * crop.height)

    modes = (
        # bottom, leftmost and rightmost left edge for a width, nearness to prefer
        (min(y0 - 1.5, ry + 13.0), lambda w: max(8.0, rx0 - OVERHANG), lambda w: min(pw - 8.0, rx1 + OVERHANG) - w,
         lambda left, w: -abs(left + w / 2 - mid)),
        (y1 + 13.0, lambda w: rx1 + 4.0, lambda w: right_edge - w,
         lambda left, w: -min([abs(left - a[0]) for a in annots] or [left - rx1])),
    )
    for n, (bottom, lo_of, hi_of, near) in enumerate(modes):
        obstacles = [o[:4] for o in others if o[1] < bottom]

        def fits(scale):
            """Every free position at this scale: (h bucket, nearness, left, h, picture share)."""
            width = STAMP_W * scale
            lo, hi = lo_of(width), hi_of(width)
            if hi < lo and n == 0:   # a line shorter than the art: centred on it
                lo = hi = max(8.0, min(mid - width / 2, pw - 8.0 - width))
            lefts = [lo + i for i in range(int(max(0.0, hi - lo)) + 1)] + [a[0] for a in annots if lo <= a[0] <= hi]
            out = []
            for left in lefts:
                hit = [o for o in obstacles if o[0] < left + width - 0.5 and o[2] > left + 0.5]
                if any(o[3] > bottom for o in hit):   # something reaches into the art's bottom edge
                    continue
                top_limit = max([o[3] for o in hit] + [bottom - 220.0, 0.0])
                h = min(STAMP_H_MAX, (bottom - top_limit - GAP_ABOVE) / scale) * scale
                if h >= STAMP_H_MIN * scale:
                    out.append((round(h / 4), near(left, width), left, h, picture_share(left, bottom - h, left + width, bottom)))
            return out

        full = fits(1.0)
        if not full:
            continue
        clear = [f for f in full if f[4] <= PICTURE_CLEAR]
        if clear:
            _, _, left, h, _ = max(clear)
            return left, bottom - h, STAMP_W, h, 1.0
        for i in range(1, int(round((1 - SCALE_MIN) / 0.05)) + 1):
            scale = round(1 - 0.05 * i, 2)
            clear = [f for f in fits(scale) if f[4] <= PICTURE_CLEAR]
            if clear:
                _, _, left, h, _ = max(clear)
                return left, bottom - h, STAMP_W * scale, h, scale
        _, _, left, h, _ = max(full, key=lambda f: (f[0], -f[4], f[1]))
        return left, bottom - h, STAMP_W, h, 1.0
    return None


def _pages_meta(data):
    """Per page: crop box, rotation and the rectangles of its visible annotations (PDF points)."""
    from io import BytesIO
    from pyhanko.pdf_utils.reader import PdfFileReader
    from pyhanko.pdf_utils.rw_common import find_inherited_value_in_tree
    r = PdfFileReader(BytesIO(data), strict=False)
    out = []

    def walk(node):
        node = node.get_object()
        if node.get("/Type") == "/Pages":
            for kid in node["/Kids"]:
                walk(kid)
            return
        box = find_inherited_value_in_tree(node, "/CropBox", "/Parent") or \
            find_inherited_value_in_tree(node, "/MediaBox", "/Parent")
        annots, ours = [], []
        for a in node.get("/Annots", []) or []:
            a = a.get_object()
            try:
                ax0, ay0, ax1, ay1 = [float(v) for v in a["/Rect"]]
            except (KeyError, TypeError, ValueError):
                continue
            if abs(ax1 - ax0) * abs(ay1 - ay0) > 0:
                annots.append((min(ax0, ax1), min(ay0, ay1), max(ax0, ax1), max(ay0, ay1)))
                if str(a.get("/NM", "")).startswith(STAMP_NM):   # art from an earlier wyglad, and whose
                    ours.append((annots[-1], str(a.get("/T", ""))))
        bx = [float(v) for v in box]
        out.append({"box": (min(bx[0], bx[2]), min(bx[1], bx[3]), max(bx[0], bx[2]), max(bx[1], bx[3])),
                    "rotate": int(find_inherited_value_in_tree(node, "/Rotate", "/Parent") or 0) % 360,
                    "annots": annots, "ours": ours})

    walk(r.root["/Pages"])
    return out


def _signature_lines(pdf, nad, strona, meta):
    """The signature lines of `nad` in the document's signature block: ([{strona, rect}], skipped).

    A signature line of a name is a rule, typed (underscores, dots) or drawn (at most 3 pt thick,
    at least 60 pt long), at most 30 pt above the name and reaching over it, with nothing on the
    name's line between the start of the rule and the name but a label ending with ':' ("Name:"),
    and room above it for the art. A block without a rule counts too when the name stands alone
    with a signature caption under it (_caption_rule). A name in the text (the parties, a
    definition, a table) has neither. Every such place on every page counts: one person may sign
    twice (for a company and in person), and annexes and exhibits bound into the file carry their
    own blocks. A place that already has this person's art from an earlier wyglad is skipped, the
    others on its page are not. --strona keeps the art to one page.
    """
    from PIL import Image, ImageDraw
    scale = 2.0
    found, skipped = {}, []
    for pi, p in enumerate(_words(pdf)):
        hits = list(_name_hits(p["words"], nad))
        if not hits:
            continue
        m = meta[pi]
        if m["rotate"]:
            skipped.append({"strona": pi + 1, "powod": f"strona obrócona o {m['rotate']} stopni"})
            continue
        bx0, by0, _, by1 = m["box"]
        ph = p["h"]
        annots = [(a[0] - bx0, ph - (a[3] - by0), a[2] - bx0, ph - (a[1] - by0)) for a in m["annots"]]
        # this person's art from an earlier wyglad belongs to the name it stands over (or beside)
        done = set()
        for a, who in m["ours"]:
            if _fold(who) != _fold(nad):
                continue
            a = (a[0] - bx0, ph - (a[3] - by0), a[2] - bx0, ph - (a[1] - by0))
            near = [(abs(n[1] - a[3]), i) for i, n in enumerate(hits) if -30.0 <= n[1] - a[3] <= 60.0]
            if near:
                done.add(min(near)[1])
        img = pictures = None

        def render():
            with tempfile.TemporaryDirectory() as td:
                base = os.path.join(td, "p")
                subprocess.run(["pdftoppm", "-r", str(int(72 * scale)), "-gray", "-png", "-f", str(pi + 1),
                                "-l", str(pi + 1), "-singlefile", pdf, base], check=True)
                return Image.open(base + ".png").convert("L")

        for i, name in enumerate(hits):
            if i in done:
                skipped.append({"strona": pi + 1, "powod": "już ma grafikę podpisu z wyglad"})
                continue
            rule = _text_rule(p["words"], name)
            if rule is None:
                img = img or render()
                rule = _drawn_rule(img, scale, name)
            if rule is None:
                rule = _caption_rule(p["words"], name)
            if rule is None:
                skipped.append({"strona": pi + 1, "powod": "nazwisko w treści (nie ma nad nim linii podpisu)"})
                continue
            between = sorted((w for w in p["words"] if _same_line(w, name) and w[2] <= name[0] + 0.5
                              and w[0] >= rule[0] - 2), key=lambda w: w[0])
            if between and not (len(between) <= 3 and between[-1][4].endswith(":")):
                skipped.append({"strona": pi + 1, "powod": "nazwisko w treści (w wierszu przed nim jest tekst)"})
                continue
            img = img or render()
            if pictures is None:   # the page without its text: what is left is lines and pictures
                pictures = img.copy()
                d = ImageDraw.Draw(pictures)
                for w in p["words"]:
                    d.rectangle([(w[0] - 1) * scale, (w[1] - 1) * scale, (w[2] + 1) * scale, (w[3] + 1) * scale],
                                fill=255)
            box = _art_box(p["words"], annots, pictures, scale, name, rule, p["w"])
            if box is None:
                skipped.append({"strona": pi + 1, "powod": "za mało miejsca nad linią podpisu"})
                continue
            left, top, width, h, scale = box
            rect = [round(bx0 + left, 2), round(by0 + ph - (top + h), 2),
                    round(bx0 + left + width, 2), round(by0 + ph - top, 2)]
            found.setdefault(pi + 1, []).append({"rect": rect, "skala": scale})
    if strona:
        if strona not in found:
            raise Blad("brak_linii", f"Na stronie {strona} nie znalazłem linii podpisu nad „{nad}”.")
        for other in sorted(found):
            if other != strona:
                skipped.extend({"strona": other, "powod": "inna strona niż --strona"} for _ in found[other])
        found = {strona: found[strona]}
    if not found:
        if any(s["powod"] == "już ma grafikę podpisu z wyglad" for s in skipped):
            raise Blad("brak_linii", f"Każda linia podpisu nad „{nad}” ma już grafikę.")
        raise Blad("brak_linii", f"Nie znalazłem linii podpisu nad „{nad}”.")
    return [{"strona": page, **r} for page in sorted(found) for r in found[page]], skipped


def _cut_last(data, nad):
    """When the last signature is `nad`'s, the file as it was before that signature.

    The signature must cover the whole file (it is the last revision); the cut is at the end of
    the revision before it: its xref section, then %%EOF and one end-of-line, the bytes the
    signature's own update starts after. The prefix is checked: it has one revision fewer, the
    same earlier signatures, and the signature right before the cut covers it to the last byte.
    Someone else's last signature is never cut: (data, None).
    """
    from io import BytesIO
    from pyhanko.pdf_utils.reader import PdfFileReader
    r = PdfFileReader(BytesIO(data), strict=False)
    sigs = sorted(r.embedded_signatures, key=lambda e: e.signed_revision)
    if not sigs:
        return data, None
    last = sigs[-1]
    cn = last.signer_cert.subject.native.get("common_name") or ""
    if _fold(cn) != _fold(nad):
        return data, None
    _, b, c, d = [int(v) for v in last.byte_range]
    rev = last.signed_revision
    if c + d != len(data) or rev != r.xrefs.total_revisions - 1:
        raise Blad("cofniecie", f"Po ostatnim podpisie ({cn}) dopisano coś jeszcze, więc go nie odcinam. "
                                "Sprawdź plik albo użyj --bez-cofania.")
    if rev == 0:
        raise Blad("cofniecie", f"Podpis {cn} jest w pierwszej wersji pliku: nie ma wersji sprzed niego.")
    end = r.xrefs.get_xref_container_info(rev - 1).end_location
    i = data.find(b"%%EOF", end)
    if i < 0 or i + 5 > b:
        raise Blad("cofniecie", "Nie widzę końca wersji pliku sprzed ostatniego podpisu; nic nie odcinam.")
    cut = i + 5
    if data[cut:cut + 2] == b"\r\n":
        cut += 2
    elif data[cut:cut + 1] in (b"\n", b"\r"):
        cut += 1
    prefix = data[:cut]
    for e in sigs[:-1]:
        if e.signed_revision == rev - 1 and int(e.byte_range[2]) + int(e.byte_range[3]) != cut:
            raise Blad("cofniecie", f"Podpis {e.field_name} nie kończy się tam, gdzie zaczyna się ostatni; "
                                    "nic nie odcinam.")
    r2 = PdfFileReader(BytesIO(prefix), strict=False)
    if r2.xrefs.total_revisions != rev or \
            sorted(e.field_name for e in r2.embedded_signatures) != sorted(e.field_name for e in sigs[:-1]):
        raise Blad("cofniecie", "Wersja sprzed ostatniego podpisu nie czyta się jak należy; nic nie odcinam.")
    return prefix, {"podpisal": cn, "pole": last.field_name, "czas": str(last.self_reported_timestamp),
                    "bajty_przed": len(data), "bajty_po": cut, "sha256_po": hashlib.sha256(prefix).hexdigest()}


def _stamp_policy():
    """pyHanko's default diff policy, able to tell a plain /Stamp annotation from other changes.

    The default policy has no rule at the ANNOTATIONS level (its docs: "currently unused"), so it
    calls any annotation added after a signature OTHER, a highlight as much as a rewritten page.
    pyHanko compares every later revision with the signed one, so a stamp also trips its
    signature-field rule in each revision after it: "newly added annotations not recognised".

    This policy takes the page walk out of that rule (approve_widget_bindings=False) and does it
    itself. A page whose /Annots only gained annotations, none lost, each new in its revision and
    either a plain /Stamp (no action, not a form field) or the widget of a new signature field,
    and whose dictionary changed in nothing else, is cleared at LTA_UPDATES, as pyHanko clears a
    signature's widget; each stamp with its appearance (only objects new since the signed
    revision) at ANNOTATIONS. Whatever it does not clear stays unexplained, so OTHER.
    """
    from pyhanko.pdf_utils import generic
    from pyhanko.sign.diff_analysis import (DEFAULT_DIFF_POLICY, FormUpdatingRule, GenericFieldModificationRule,
                                            ModificationLevel, QualifiedWhitelistRule, ReferenceUpdate,
                                            SigFieldCreationRule, SigFieldModificationRule, StandardDiffPolicy)
    from pyhanko.sign.diff_analysis.commons import compare_dicts

    def refs(node, key):
        """The references in an array of indirect objects under `key`; [] without it, None if odd."""
        try:
            arr = node.raw_get(key).get_object()
        except KeyError:
            return []
        if not isinstance(arr, generic.ArrayObject) or not all(isinstance(x, generic.IndirectObject) for x in arr):
            return None
        return [x.reference for x in arr]

    class PagesWithStamps(QualifiedWhitelistRule):
        def apply_qualified(self, old, new):
            yield from self._walk(old, new, old.root.raw_get("/Pages"), new.root.raw_get("/Pages"))

        def _walk(self, old, new, old_ref, new_ref):
            o, n = old_ref.get_object(), new_ref.get_object()
            if o.get("/Type") == "/Pages":
                old_kids, new_kids = refs(o, "/Kids"), refs(n, "/Kids")
                if old_kids and old_kids == new_kids:   # a changed page tree is not ours to clear
                    for a, b in zip(o.raw_get("/Kids").get_object(), n.raw_get("/Kids").get_object()):
                        yield from self._walk(old, new, a, b)
                return
            old_annots, new_annots = refs(o, "/Annots"), refs(n, "/Annots")
            if old_annots is None or new_annots is None or set(old_annots) - set(new_annots):
                return
            added = set(new_annots) - set(old_annots)
            if not added:
                return
            known = True
            for ref in added:
                annot = new(ref)
                if not old.is_ref_unassignable(ref) or not isinstance(annot, generic.DictionaryObject):
                    known = False
                elif annot.get("/Subtype") == "/Stamp" and not any(k in annot for k in ("/A", "/AA", "/FT", "/Parent", "/Kids")):
                    yield ModificationLevel.ANNOTATIONS, ReferenceUpdate(ref)
                    for dep in new.collect_dependencies(annot, since_revision=old.revision + 1):
                        yield ModificationLevel.ANNOTATIONS, ReferenceUpdate(dep)
                elif annot.get("/Subtype") == "/Widget" and (
                        annot.get("/FT") == "/Sig" or ("/Parent" in annot and annot["/Parent"].get("/FT") == "/Sig")):
                    pass   # a new signature field's widget: the field rules clear it
                else:
                    known = False
            if known and compare_dicts(o, n, frozenset(["/Annots"]), raise_exc=False):
                yield ModificationLevel.LTA_UPDATES, ReferenceUpdate(new_ref.reference)
                annots_value = n.raw_get("/Annots")
                if isinstance(annots_value, generic.IndirectObject):
                    yield ModificationLevel.LTA_UPDATES, ReferenceUpdate(annots_value.reference)

    return StandardDiffPolicy(
        global_rules=list(DEFAULT_DIFF_POLICY.global_rules) + [PagesWithStamps()],
        form_rule=FormUpdatingRule(field_rules=[SigFieldCreationRule(approve_widget_bindings=False),
                                                SigFieldModificationRule(), GenericFieldModificationRule()]))


def _check_signatures(data):
    """Every signature in `data`: intact or not, and what came after it, by pyHanko's default diff
    policy (zmiany_po, as in sprawdz) and by that policy with the stamp rule (zmiany_po_wyglad)."""
    from io import BytesIO
    from pyhanko.pdf_utils.reader import PdfFileReader
    from pyhanko.sign.validation import validate_pdf_signature
    from pyhanko_certvalidator import ValidationContext
    _pyhanko_quiet()
    rows = []
    for key, policy in (("zmiany_po", None), ("zmiany_po_wyglad", _stamp_policy())):
        r = PdfFileReader(BytesIO(data), strict=False)   # a fresh reader: no diff result carried over
        for i, es in enumerate(sorted(r.embedded_signatures, key=lambda e: e.signed_revision)):
            st = validate_pdf_signature(es, ValidationContext(allow_fetching=False), diff_policy=policy)
            if len(rows) <= i:
                rows.append({"pole": es.field_name, "podpisal": es.signer_cert.subject.native.get("common_name"),
                             "integralnosc": st.intact and st.valid, "obejmuje": st.coverage.name})
            rows[i][key] = st.modification_level.name if st.modification_level else None
    return rows


def _add_art(data, slots, when, nad, workdir):
    """`data` plus one incremental update: a locked /Stamp annotation with the art on every slot."""
    import uuid
    from io import BytesIO
    from pyhanko.pdf_utils import generic
    from pyhanko.pdf_utils.generic import pdf_date, pdf_name, pdf_string
    from pyhanko.pdf_utils.incremental_writer import IncrementalPdfFileWriter
    from pyhanko.pdf_utils.reader import PdfFileReader
    w = IncrementalPdfFileWriter(BytesIO(data), strict=False)
    now = datetime.now().astimezone()
    num = lambda v: generic.FloatObject(round(v, 3))
    for i, slot in enumerate(slots):
        x1, y1, x2, y2 = slot["rect"]
        bw, bh = round(x2 - x1, 2), round(y2 - y1, 2)
        scale = slot.get("skala", 1.0)   # drawn at full size, shown smaller next to a picture
        art = os.path.join(workdir, f"podpis-{i}.pdf")
        _stamp_pdf(art, when, round(bw / scale, 2), round(bh / scale, 2), False, nad)
        with open(art, "rb") as f:
            art_reader = PdfFileReader(BytesIO(f.read()), strict=False)
        xo = w.import_page_as_xobject(art_reader, 0)
        ax0, ay0, ax1, ay1 = [float(v) for v in xo.get_object()["/BBox"]]
        sx, sy = bw / (ax1 - ax0), bh / (ay1 - ay0)
        ap = generic.StreamObject({
            pdf_name("/Type"): pdf_name("/XObject"),
            pdf_name("/Subtype"): pdf_name("/Form"),
            pdf_name("/BBox"): generic.ArrayObject([num(0), num(0), num(bw), num(bh)]),
            pdf_name("/Resources"): generic.DictionaryObject({
                pdf_name("/XObject"): generic.DictionaryObject({pdf_name("/Podpis"): xo}),
                # ink, not paint: a seal or a printed line under the signature shows through
                pdf_name("/ExtGState"): generic.DictionaryObject({pdf_name("/Atrament"): generic.DictionaryObject({
                    pdf_name("/Type"): pdf_name("/ExtGState"), pdf_name("/BM"): pdf_name("/Multiply")})}),
            }),
        }, stream_data=f"q /Atrament gs {sx:.6f} 0 0 {sy:.6f} {-ax0 * sx:.4f} {-ay0 * sy:.4f} cm /Podpis Do Q".encode())
        page_ref, _ = w.find_page_for_modification(slot["strona"] - 1)
        annot = generic.DictionaryObject({
            pdf_name("/Type"): pdf_name("/Annot"),
            pdf_name("/Subtype"): pdf_name("/Stamp"),
            pdf_name("/Rect"): generic.ArrayObject([num(x1), num(y1), num(x2), num(y2)]),
            pdf_name("/P"): page_ref,
            pdf_name("/F"): generic.NumberObject(STAMP_FLAGS),
            pdf_name("/AP"): generic.DictionaryObject({pdf_name("/N"): w.add_object(ap)}),
            pdf_name("/NM"): pdf_string(f"{STAMP_NM}{uuid.uuid4()}"),
            pdf_name("/T"): pdf_string(nad),
            pdf_name("/Contents"): pdf_string(f"Podpis: {nad}"),
            pdf_name("/M"): pdf_date(now),
        })
        w.register_annotation(page_ref, w.add_object(annot))
    out = BytesIO()
    w.write(out)
    return out.getvalue()


def _wyglad_one(plik, nad, when, args):
    with open(plik, "rb") as f:
        data = f.read()
    if not data.startswith(b"%PDF"):
        raise Blad("nie_pdf", "To nie jest PDF.")
    name = os.path.basename(plik)
    if args.out_dir:
        out = os.path.join(args.out_dir, name)
    else:
        out = os.path.join(os.path.dirname(os.path.abspath(plik)),
                           re.sub(r"\.pdf$", "", name, flags=re.I) + WYGLAD_SUFFIX + ".pdf")
    if os.path.abspath(out) == os.path.abspath(plik):
        raise Blad("nadpisanie", "Wynik trafiłby na oryginał. Wskaż inny --out-dir.")
    base, cofniety = (data, None) if args.bez_cofania else _cut_last(data, nad)
    with tempfile.TemporaryDirectory() as td:
        src = os.path.join(td, "przed.pdf")
        with open(src, "wb") as f:
            f.write(base)
        slots, skipped = _signature_lines(src, nad, args.strona, _pages_meta(base))
        result = _add_art(base, slots, when, nad, td)
    # the proof that only the art was added, before anything is written
    if not result.startswith(base):
        raise Blad("kontrola", "Wynik nie zaczyna się od pliku wejściowego; nic nie zapisałem.")
    podpisy = _check_signatures(result)
    for p in podpisy:
        if not p["integralnosc"] or p["zmiany_po_wyglad"] == "OTHER":
            raise Blad("kontrola", f"Po wstawieniu grafiki podpis {p['podpisal']} ({p['pole']}) nie jest nienaruszony "
                                   f"albo zmiany po nim to nie tylko grafika; nic nie zapisałem.")
    uwagi = []
    if podpisy and _fold(podpisy[-1]["podpisal"]) == _fold(nad) and podpisy[-1]["obejmuje"] != "ENTIRE_FILE":
        uwagi.append(f"Ostatni podpis ({podpisy[-1]['podpisal']}) nie obejmuje już całego pliku: podpisz plik ponownie.")
    tmp = out + ".tmp"
    try:
        with open(tmp, "wb") as f:
            f.write(result)
        os.replace(tmp, out)
    except OSError as e:
        raise Blad("zapis", f"Nie mogę zapisać {out}: {e.strerror}. Wskaż --out-dir.")
    return {"ok": True, "zrodlo": plik, "plik": out, "cofniety": cofniety, "miejsca": slots, "pominiete": skipped,
            "podpisy": podpisy, "wejscie_jest_prefiksem": True, "bajty_wejscia": len(base), "uwagi": uwagi,
            "sha256": hashlib.sha256(result).hexdigest()}


def _wyglad_podpisz_one(plik, nad, when, args, signer, name):
    """The art, then the token's invisible signature over it, which covers the art too. Only the
    signed file is written (name-podpisany.pdf); with no signature line it is signed without art."""
    import pkcs11
    base = os.path.basename(plik)
    if args.out_dir:
        out = os.path.join(args.out_dir, base)
    else:
        out = os.path.join(os.path.dirname(os.path.abspath(plik)),
                           re.sub(r"\.pdf$", "", base, flags=re.I) + PODPISANY_SUFFIX + ".pdf")
    if os.path.abspath(out) == os.path.abspath(plik):
        raise Blad("nadpisanie", "Wynik trafiłby na oryginał. Wskaż inny --out-dir.")
    with tempfile.TemporaryDirectory() as td:
        art_dir = os.path.join(td, "grafika")   # its own folder: the file keeps its name there
        os.mkdir(art_dir)
        try:
            res = _wyglad_one(plik, nad, when, argparse.Namespace(**{**vars(args), "out_dir": art_dir}))
        except Blad as e:
            if e.kod != "brak_linii":
                raise
            with open(plik, "rb") as f:
                data = f.read()
            if not data.startswith(b"%PDF"):
                raise Blad("nie_pdf", "To nie jest PDF.")
            # your own last signature goes, as with the art: signed again, not twice
            base, cofniety = (data, None) if args.bez_cofania else _cut_last(data, nad)
            src = os.path.join(td, "bez-grafiki.pdf")
            with open(src, "wb") as f:
                f.write(base)
            res = {"zrodlo": plik, "plik": src, "cofniety": cofniety, "miejsca": [], "pominiete": [],
                   "uwagi": [f"{e.tekst} Podpisałem bez nowej grafiki."]}
        signed_path = os.path.join(td, "podpisany.pdf")
        _show_cloudsigner(signer)
        try:
            _sign_pdf(res["plik"], signed_path, signer, name)
        except pkcs11.exceptions.PKCS11Error as e:
            raise Blad("podpis", f"Podpis się nie udał ({type(e).__name__}): odrzucony albo niezatwierdzony "
                                 "na telefonie, albo CloudSigner przerwał. Nic nie zapisałem.")
        with open(res["plik"], "rb") as f:
            before = f.read()
        with open(signed_path, "rb") as f:
            signed = f.read()
    # the proof, before anything is written: the art stays a byte prefix and the new signature covers it all
    if not signed.startswith(before):
        raise Blad("kontrola", "Podpisany plik nie zaczyna się od pliku z grafiką; nic nie zapisałem.")
    podpisy = _check_signatures(signed)
    if not podpisy or not podpisy[-1]["integralnosc"] or podpisy[-1]["obejmuje"] != "ENTIRE_FILE":
        raise Blad("kontrola", "Nowy podpis nie jest nienaruszony albo nie obejmuje całego pliku; nic nie zapisałem.")
    tmp = out + ".tmp"
    try:
        with open(tmp, "wb") as f:
            f.write(signed)
        os.replace(tmp, out)
    except OSError as e:
        raise Blad("zapis", f"Nie mogę zapisać {out}: {e.strerror}. Wskaż --out-dir.")
    return {**res, "ok": True, "zrodlo": plik, "plik": out, "podpisal": name, "podpisy": podpisy,
            "uwagi": [u for u in res["uwagi"] if "podpisz plik ponownie" not in u],
            "sha256": hashlib.sha256(signed).hexdigest()}


def cmd_wyglad(args):
    """The art of your signature on your signature lines, before you sign with another tool,
    or with --podpisz signed right away with the token (the mSzafir flow)."""
    nad = args.nad or _config().get("imie")
    if not nad:
        raise Blad("brak_nazwiska", "Podaj --nad 'Imię Nazwisko' albo ustaw \"imie\" w config.json.")
    if args.out_dir and not os.path.isdir(args.out_dir):
        raise Blad("out_dir", f"Nie ma folderu {args.out_dir}.")
    when = args.data or datetime.now().strftime("%d.%m.%Y")
    session = signer = name = None
    if args.podpisz:
        session, pin = _open_signing_session(args)   # no token, nothing written
    wyniki = []
    try:
        if session:
            signer, name = _signer(session, pin)
        for plik in args.plik:
            try:
                wyniki.append(_wyglad_podpisz_one(plik, nad, when, args, signer, name) if signer
                              else _wyglad_one(plik, nad, when, args))
            except Blad as e:
                wyniki.append({"ok": False, "zrodlo": plik, "kod": e.kod, "blad": e.tekst})
    finally:
        if session:
            _close(session)
    return {"ok": all(w["ok"] for w in wyniki), "nad": nad, "podpisane": bool(signer), "pliki": wyniki}


def main():
    p = argparse.ArgumentParser(prog="podpisz", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--json", action="store_true")
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--json", action="store_true", default=argparse.SUPPRESS)
    common.add_argument("--czekaj", type=int, default=0, help="czekaj do N s na czytnik i kartę")
    auth = argparse.ArgumentParser(add_help=False)
    auth.add_argument("--pin-stdin", action="store_true")
    auth.add_argument("--wymus", action="store_true", help="pozwól na ostatnią próbę PIN-u")
    sign = argparse.ArgumentParser(add_help=False, parents=[auth])
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
    pw = sub.add_parser("wyglad", parents=[common, auth])
    pw.add_argument("plik", nargs="+")
    pw.add_argument("--nad", help="imię i nazwisko pod linią podpisu (domyślnie \"imie\" z config.json)")
    pw.add_argument("--out-dir", help="folder na wyniki (domyślnie obok oryginału, z dopiskiem -do-podpisu)")
    pw.add_argument("--strona", type=int, help="tylko ta strona (domyślnie każda strona z Twoją linią podpisu, także w załącznikach)")
    pw.add_argument("--bez-cofania", action="store_true",
                    help="nie odcinaj ostatniego podpisu, nawet gdy złożyła go osoba z --nad")
    pw.add_argument("--data", help="data w podpisie nad grafiką (domyślnie dziś, DD.MM.RRRR)")
    pw.add_argument("--podpisz", action="store_true",
                    help="od razu podpisz kartą albo mSzafirem, niewidocznie, pod grafiką "
                         "(wynik: nazwa-podpisany.pdf, bez pliku -do-podpisu)")
    a = p.parse_args()
    try:
        if getattr(a, "czekaj", 0) and (a.cmd in ("status", "pdf", "xml") or getattr(a, "podpisz", False)):
            _wait_for_card(a.czekaj)
        res = {"status": cmd_status, "miejsce": cmd_miejsce, "pdf": cmd_pdf, "grafika": cmd_grafika,
               "xml": cmd_xml, "sprawdz": cmd_sprawdz, "wyglad": cmd_wyglad}[a.cmd](a)
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
        elif "kod" in res:
            print(f"BŁĄD ({res['kod']}): {res['blad']}", file=sys.stderr)
        else:   # a batch where some files failed (wyglad): every file's line
            for w in res.get("pliki", []):
                if w.get("ok"):
                    print(f"plik: {w['plik']}")
                else:
                    print(f"BŁĄD ({w['kod']}) {w['zrodlo']}: {w['blad']}", file=sys.stderr)
    sys.exit(code)


if __name__ == "__main__":
    main()
