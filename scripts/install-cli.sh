#!/bin/bash
# Installs the podpisz CLI: a Python venv in $PODPIS_HOME (default ~/.local/share/podpis)
# and a launcher in $PODPIS_BIN (default ~/.local/bin), where Podpis.app looks for it.
#   scripts/install-cli.sh
set -euo pipefail
cd "$(dirname "$0")/.."

DATA=${PODPIS_HOME:-$HOME/.local/share/podpis}
BIN=${PODPIS_BIN:-$HOME/.local/bin}
PY=${PYTHON:-python3}

fail() { echo "podpisz: $1" >&2; exit 1; }
command -v "$PY" >/dev/null || fail "brak Pythona. Zainstaluj Pythona 3.11+ (python.org albo brew install python)."
"$PY" -c 'import sys; sys.exit(sys.version_info < (3, 11))' || fail "potrzebny Python 3.11 lub nowszy."
command -v pdftotext >/dev/null || fail "brak poppler: brew install poppler"
# xmlsec1 checks XML signatures only: without it everything but `podpisz xml` works.
command -v xmlsec1 >/dev/null || echo "Uwaga: brak xmlsec1 (brew install libxmlsec1): bez niego nie działa podpisz xml."

mkdir -p "$DATA" "$BIN"
[ -x "$DATA/venv/bin/python" ] || "$PY" -m venv "$DATA/venv"
PIP=("$DATA/venv/bin/python" -m pip install --quiet --disable-pip-version-check)
if ! "${PIP[@]}" -r cli/requirements.txt; then
  # python-pkcs11 is a C extension: on a Python too new for its wheels it has to build from source and
  # may fail. Only the card needs it (status, pdf, xml); wyglad, miejsce, grafika and sprawdz do not.
  "${PIP[@]}" $(grep -v '^python-pkcs11' cli/requirements.txt)
  echo "Uwaga: python-pkcs11 się nie zainstalował, więc karta nie działa (status, pdf, xml)." \
       "Działają wyglad, miejsce, grafika i sprawdz. Spróbuj z innym Pythonem: PYTHON=python3.13 $0"
fi
install -m 644 cli/podpisz.py "$DATA/podpisz.py"
cat > "$BIN/podpisz" <<LAUNCHER
#!/bin/sh
PODPIS_HOME="\${PODPIS_HOME:-$DATA}" exec "$DATA/venv/bin/python" -I "$DATA/podpisz.py" "\$@"
LAUNCHER
chmod 755 "$BIN/podpisz"
echo "Zainstalowano: $BIN/podpisz"

# What the CLI needs at run time but cannot install itself.
[ -e "$DATA/libPKCS11Graphite.dylib" ] || [ -e /Applications/Szafir2.app/Contents/app/libPKCS11Graphite.dylib ] \
  || [ -e "$HOME/Applications/Szafir2.app/Contents/app/libPKCS11Graphite.dylib" ] || [ -n "${PODPIS_PKCS11:-}" ] \
  || echo "Uwaga: nie widzę sterownika karty. Zainstaluj Szafir2 od KIR (sterownik jest w jego paczce) albo ustaw PODPIS_PKCS11."
browser=""
for app in "Google Chrome" Chromium "Brave Browser" "Microsoft Edge"; do
  [ -e "/Applications/$app.app" ] || [ -e "$HOME/Applications/$app.app" ] && browser=$app
done
[ -n "$browser" ] || [ -n "${PODPIS_PRZEGLADARKA:-}" ] \
  || echo "Uwaga: do rysowania podpisu potrzebny jest Chrome, Chromium, Brave albo Edge."
case ":$PATH:" in *":$BIN:"*) ;; *) echo "Dodaj $BIN do PATH, żeby wołać podpisz z terminala." ;; esac
