# Podpis

**Sign PDF and XML files with a Polish qualified electronic signature on a Mac. Native, no Java, no Rosetta.**

[Po polsku](README.pl.md)

Drop a document in, Podpis finds your name on the signature line and puts your signature there, you type the PIN once, and the signed file lands next to the original. The signature is computed on your card, so it is a qualified electronic signature, legally equal to a handwritten one (eIDAS, art. 25(2)).

Podpis is a small macOS app and the `podpisz` command line tool underneath it. It was built for the Szafir card from KIR, whose official app, Szafir2, is an Intel build on Java 15. On Apple silicon that means Rosetta 2, and macOS 27 is the last release where Rosetta works for general apps.

## What it does

- **PDF (PAdES baseline B).** A visible signature on the page, placed on the line above your name. Drag it, double click to move it, Option and the arrow keys nudge it by a point. Rotated pages work. The original file stays byte for byte inside the signed one (incremental update), so earlier signatures stay valid and yours is added after them.
- **XML (XAdES-BES, enveloped).** For XML documents such as JPK metadata or e-financial statements. Each XML signature is checked with `xmlsec1` before the file is written. XML metadata signed this way has been accepted by the Polish Ministry of Finance gateway (JPK_V7M, UPO received).
- **Batches.** Many files, one PIN. You can stop after the current file.
- **Card status.** The reader and card are checked every two seconds while the app is in front. Plug the reader in whenever you like: every call starts a fresh process that loads the card driver anew.
- **Touch ID.** Optional. The PIN goes to your Keychain only after a signature succeeds, and Touch ID is skipped when the card is on its last PIN try.
- **Your look.** Your handwritten signature from a PNG, or your name from the certificate set in a script font. Under it a small line: "Kwalifikowany podpis elektroniczny" and the time.
- **The look for a signature made with another tool.** `podpisz wyglad` and the Wstaw podpis app put the same look on your signature lines before you sign the file with a tool that signs invisibly. No card, no PIN.

## What it does not do

- No timestamps (no PAdES-T or XAdES-T), no long-term formats, no PKCS#7 (.sig) files. Szafir2 has timestamps, XAdES-T/C/A and PKCS#7.
- `podpisz sprawdz` checks that a signature is intact and covers the file. It does not check the trust chain. For a formal check use the official KIR or EU validators.
- Only the Szafir card from KIR has been tested (token "PKI Token 2 (QSCD)", ACS ACR40T reader). Cards from other providers need their own PKCS#11 driver and token label (see Settings below). They may work, but nobody has tried yet.

## Requirements

- macOS 26 or newer. Tested on macOS 27.0.1, Apple silicon.
- **Szafir2 from KIR installed.** Podpis does not ship the card driver. It uses `libPKCS11Graphite.dylib` (CryptoTech), a universal binary that comes inside `Szafir2.app`. You keep Szafir2 installed only for that file.
- Python 3.11 or newer, `brew install poppler libxmlsec1` (`xmlsec1` for XML signatures only).
- Google Chrome, Chromium, Brave or Edge, used headless to draw the signature art.
- Xcode 26 to build the app.

## Install

```bash
git clone https://github.com/outof-place/podpis.git
cd podpis
scripts/install-cli.sh      # podpisz CLI: venv in ~/.local/share/podpis, launcher in ~/.local/bin
scripts/build-app.sh        # Podpis.app into /Applications
scripts/build-droplet.sh    # Wstaw podpis.app into /Applications (the look for another tool's signature)
podpisz status              # reader, card, certificate (no PIN)
```

The app is built and signed ad hoc on your own Mac, so it opens without a Gatekeeper prompt. There are no prebuilt downloads.

## Your signature

Put your handwritten signature in `~/.local/share/podpis/sygnatura.png`: a PNG with a transparent background, cropped tight, about 1000 px wide. Without it, Podpis writes your name from the certificate in a script font.

Optional settings go in `~/.local/share/podpis/config.json`. Every key has a default:

```json
{
  "podpis_png": "~/Documents/moj-podpis.png",
  "imie": "Jan Kowalski",
  "sterownik": "/Applications/Szafir2.app/Contents/app/libPKCS11Graphite.dylib",
  "token": "PKI Token 2 (QSCD)",
  "przegladarka": "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  "pieczec": {"gora": "PRZYKŁADOWA SPÓŁKA SP. Z O.O.", "dol": "WARSZAWA", "srodek": ["PIECZĘĆ", "SPÓŁKI"], "rok": "2026"}
}
```

`pieczec` draws a round company seal next to the signature, but only with `podpisz pdf --pieczec tak`. The seal is decoration: no Polish law requires one, and the qualified signature alone carries the legal effect.

Environment variables: `PODPIS_HOME` (settings folder), `PODPIS_PKCS11` (driver path), `PODPIS_PRZEGLADARKA` (browser binary), `PODPIS_CLI` (which `podpisz` the app runs).

## Command line

The CLI speaks Polish, like the documents it signs. Add `--json` for machine output: exit 0 ok, 2 a known error `{"ok": false, "kod": "...", "blad": "..."}`, 3 unexpected.

```bash
podpisz status                                   # reader, card, certificate, PIN tries left
podpisz miejsce umowa.pdf --nad "Jan Kowalski"   # where the signature would go
podpisz pdf umowa.pdf aneks.pdf --nad "Jan Kowalski"
podpisz pdf umowa.pdf --strona 2 --rect 360 120 500 168
podpisz xml jpk-metadane.xml                     # XAdES enveloped, verified with xmlsec1
podpisz sprawdz umowa-podpisany.pdf              # integrity and coverage
podpisz grafika --out podpis.png                 # the signature art alone
podpisz wyglad umowa.pdf --nad "Jan Kowalski"    # the look, before you sign with another tool
```

PIN: a native macOS prompt by default, or `--pin-stdin`. It is never written to disk or printed. After a wrong PIN, `podpisz` stops and never tries again. On the last try it refuses to sign without `--wymus`.

## The look for a signature made with another tool

Some tools (the EuroCert qualified signature made with iText, for one) only make an invisible signature. `podpisz wyglad` puts the look `podpisz pdf` draws in front of such a signature: your handwritten signature from `sygnatura.png` under a small "Kwalifikowany podpis elektroniczny · date". Then you sign the file with your tool, and your signature covers the look too. The other way round does not work: anything appended after a signature lies outside what it signs, and validators show it.

```bash
podpisz wyglad umowa.pdf aneks.pdf                         # next to the original: umowa-do-podpisu.pdf
podpisz wyglad *.pdf --nad "Jan Kowalski" --out-dir do-podpisu
```

- **Where.** On every signature line with your name (`--nad`, by default `imie` from `config.json`) on every page, so twice when you sign for a company and in person, and also in the annexes and exhibits bound into the file. A signature line is a run of underscores or dots or a drawn rule, at most 30 pt above the name and over it, with nothing before the name on its line but a label ending in a colon ("Name:"). A name in the text (the parties, a definition, a table) has no line over it, so the look does not go there. `--strona` keeps it to one page.
- **How it sits.** On the line, like ink, clear of labels ("By:"). It keeps off a seal printed on the line: when there is no room beside it the look gets smaller (down to 60%), and only when that fails too does it lie over the seal at full size. When text sits right above the line, the look goes beside the line, level with a signature already on the page. It is drawn with a Multiply blend, so whatever it lies on shows through, as under ink.
- **Earlier signatures stay intact.** The look is a locked /Stamp annotation (printed, read-only) in an incremental update: the input file stays byte for byte at the start of the result, and no page content changes. Before writing anything, `wyglad` checks every earlier signature with pyHanko and stops when one is not intact or when something other than the look came after it. In `--json`, `zmiany_po` is the verdict of pyHanko's default policy, which calls any annotation added after a signature OTHER (it has no rules for annotations), and `zmiany_po_wyglad` the same policy with a rule for plain /Stamp annotations: ANNOTATIONS means that only the look came after the signature.
- **Taking back your own signature.** When the last signature in the file is yours (the certificate's name equals `--nad`) and covers the whole file, `wyglad` cuts it off with its incremental update. What is left is the file byte for byte as it was before that signature; the look goes on top, and you sign again. It never cuts anyone else's signature. `--bez-cofania` turns the cut off: your signature then no longer covers the whole file, and `wyglad` says so.
- **No card.** `wyglad` never loads the card driver, so it works without Szafir2 and without python-pkcs11. The date above the signature is the day the look went in (`--data` changes it), because the time of the signature is not known yet. Rotated pages are skipped.
- **Wstaw podpis.app.** `scripts/build-droplet.sh` builds an app in `/Applications` (`~/Applications` when it is not writable), no admin rights. Drop PDFs on it: it runs `podpisz wyglad --json`, shows the result in a notification and reveals the files in Finder.

## How it works

- The CryptoTech PKCS#11 driver from Szafir2 talks to the card through [python-pkcs11](https://github.com/pyauth/python-pkcs11). The RSA signature is computed on the card (a qualified signature creation device), with a context-specific login for every signature.
- PDF signatures come from [pyHanko](https://github.com/MatthiasValvekens/pyHanko): PAdES baseline B, SHA-256, commitment type "proof of approval", incremental update.
- The signature art is HTML printed to PDF by a headless Chromium and used as the appearance stream.
- The signature line is found with `pdftotext -bbox` and `pdftoppm`: the stamp sits above the anchor text, may cross the rule like ink does, and stops below the nearest text above.
- XAdES-BES is built by hand with lxml (exclusive c14n, RSA-SHA256, SigningCertificate, ProofOfApproval) and checked with `xmlsec1`.
- The app is SwiftUI over the CLI. It talks to `podpisz --json`, renders the preview with the same code that draws the real stamp, and keeps the PIN in memory only for the signing run, unless you choose Touch ID.

## Development

```bash
swift test     # runs the fake CLI with the Python from scripts/install-cli.sh (or set PODPIS_PYTHON)
~/.local/share/podpis/venv/bin/python -m unittest discover -s Tests/cli -v   # podpisz wyglad
PODPIS_CLI=$PWD/Tools/fake-podpisz /Applications/Podpis.app/Contents/MacOS/Podpis
```

`Tools/fake-podpisz` simulates the card (PIN `1234`, test certificate, errors on demand through `$FAKE_PODPIS_DIR/state.json`), so the app can be developed without a reader. The app shows a "Tryb testowy" badge whenever it runs against anything other than `~/.local/bin/podpisz`. Test documents come from `Tools/make-fixtures.py`.

## Legal

Podpis is not affiliated with KIR (Krajowa Izba Rozliczeniowa S.A.) or CryptoTech. Szafir is a trademark of KIR. The card driver is theirs and is not part of this repository. You need your own qualified certificate and card.

The software comes with no warranty (see LICENSE). Read every document before you sign it.

## License

MIT. Made by [Outofplace](https://outofplace.space).
