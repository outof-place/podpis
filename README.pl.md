# Podpis

**Podpis kwalifikowany na Macu dla PDF i XML. Natywnie, bez Javy i bez Rosetty.**

[English](README.md)

Upuszczasz dokument, Podpis znajduje Twoje nazwisko na linii podpisu i stawia tam podpis. Wpisujesz PIN raz, a podpisany plik ląduje obok oryginału. Podpis liczy Twoja karta, więc to kwalifikowany podpis elektroniczny, równoważny odręcznemu (eIDAS, art. 25 ust. 2).

Podpis to mała aplikacja na macOS i narzędzie `podpisz` w terminalu, na którym stoi. Powstał dla karty Szafir z KIR, której oficjalna aplikacja Szafir2 to program na Intela z Javą 15. Na Macach z Apple silicon działa tylko przez Rosettę 2, a macOS 27 to ostatni system, w którym Rosetta obsługuje zwykłe aplikacje.

## Co robi

- **PDF (PAdES baseline B).** Widoczny podpis na stronie, na linii nad Twoim nazwiskiem. Możesz go przeciągnąć, przenieść dwuklikiem, a Option ze strzałkami przesuwa go o punkt. Obrócone strony też działają. Oryginał zostaje bajt w bajt w środku podpisanego pliku (zapis przyrostowy), więc wcześniejsze podpisy zostają ważne, a Twój dochodzi po nich.
- **XML (XAdES-BES, otaczany).** Dla plików XML, na przykład metadanych JPK albo e-sprawozdań finansowych. Każdy podpis XML jest sprawdzany przez `xmlsec1`, zanim plik zostanie zapisany. Tak podpisane metadane JPK_V7M przyjęła bramka Ministerstwa Finansów (jest UPO).
- **Wiele plików naraz.** Jeden PIN na całą paczkę. Można przerwać po bieżącym pliku.
- **Stan karty.** Czytnik i karta są sprawdzane co dwie sekundy, gdy aplikacja jest na wierzchu. Czytnik podłączasz, kiedy chcesz: każde wywołanie to nowy proces, który ładuje sterownik od nowa.
- **Touch ID.** Opcjonalnie. PIN trafia do pęku kluczy dopiero po udanym podpisie, a przy ostatniej próbie PIN-u Touch ID się nie włącza.
- **Twój wygląd.** Odręczny podpis z pliku PNG albo imię i nazwisko z certyfikatu pismem odręcznym. Pod spodem drobna linia „Kwalifikowany podpis elektroniczny” i godzina.

## Czego nie robi

- Bez znaczników czasu (bez PAdES-T i XAdES-T), bez formatów długoterminowych, bez plików PKCS#7 (.sig). Szafir2 ma znaczniki czasu, XAdES-T/C/A i PKCS#7.
- `podpisz sprawdz` sprawdza, czy podpis jest nienaruszony i obejmuje cały plik. Nie sprawdza łańcucha zaufania. Do formalnej weryfikacji służą oficjalne walidatory KIR albo UE.
- Przetestowana jest tylko karta Szafir z KIR (token „PKI Token 2 (QSCD)”, czytnik ACS ACR40T). Karty innych dostawców wymagają ich sterownika PKCS#11 i etykiety tokenu (patrz Ustawienia). Mogą działać, ale nikt jeszcze nie próbował.

## Wymagania

- macOS 26 lub nowszy. Testowane na macOS 27.0.1, Apple silicon.
- **Zainstalowany Szafir2 z KIR.** Podpis nie zawiera sterownika karty. Korzysta z `libPKCS11Graphite.dylib` (CryptoTech), uniwersalnej biblioteki z paczki `Szafir2.app`. Szafir2 zostaje na dysku tylko dla tego pliku.
- Python 3.11 lub nowszy, `brew install poppler libxmlsec1`.
- Google Chrome, Chromium, Brave albo Edge: rysują grafikę podpisu w tle.
- Xcode 26 do zbudowania aplikacji.

## Instalacja

```bash
git clone https://github.com/outof-place/podpis.git
cd podpis
scripts/install-cli.sh      # podpisz: venv w ~/.local/share/podpis, skrót w ~/.local/bin
scripts/build-app.sh        # Podpis.app do ~/Applications
podpisz status              # czytnik, karta, certyfikat (bez PIN-u)
```

Aplikację budujesz i podpisujesz ad hoc na własnym Macu, więc otwiera się bez pytań Gatekeepera. Gotowych paczek do pobrania nie ma.

## Twój podpis

Odręczny podpis wrzuć do `~/.local/share/podpis/sygnatura.png`: PNG z przezroczystym tłem, przycięty ciasno, około 1000 px szerokości. Bez niego Podpis napisze Twoje imię i nazwisko z certyfikatu pismem odręcznym.

Ustawienia (opcjonalne, każde ma wartość domyślną) w `~/.local/share/podpis/config.json`:

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

`pieczec` rysuje okrągłą pieczęć firmy obok podpisu, ale tylko z `podpisz pdf --pieczec tak`. To ozdoba: żaden przepis jej nie wymaga, skutek prawny daje sam podpis kwalifikowany.

Zmienne środowiskowe: `PODPIS_HOME` (folder ustawień), `PODPIS_PKCS11` (ścieżka sterownika), `PODPIS_PRZEGLADARKA` (przeglądarka), `PODPIS_CLI` (którego `podpisz` używa aplikacja).

## Terminal

Z `--json` wynik jest dla programów: kod 0 to sukces, 2 znany błąd `{"ok": false, "kod": "...", "blad": "..."}`, 3 błąd nieoczekiwany.

```bash
podpisz status                                   # czytnik, karta, certyfikat, próby PIN-u
podpisz miejsce umowa.pdf --nad "Jan Kowalski"   # gdzie stanie podpis
podpisz pdf umowa.pdf aneks.pdf --nad "Jan Kowalski"
podpisz pdf umowa.pdf --strona 2 --rect 360 120 500 168
podpisz xml jpk-metadane.xml                     # XAdES otaczany, sprawdzony przez xmlsec1
podpisz sprawdz umowa-podpisany.pdf              # integralność i zakres
podpisz grafika --out podpis.png                 # sama grafika podpisu
```

PIN: domyślnie natywne okienko macOS albo `--pin-stdin`. Nigdy nie trafia na dysk ani na ekran. Po złym PIN-ie `podpisz` przerywa i nie próbuje ponownie. Przy ostatniej próbie odmawia podpisu bez `--wymus`.

## Jak to działa

- Sterownik PKCS#11 CryptoTech z Szafira2 rozmawia z kartą przez [python-pkcs11](https://github.com/pyauth/python-pkcs11). Podpis RSA liczy karta (kwalifikowane urządzenie do składania podpisu), z osobnym logowaniem do każdego podpisu.
- Podpisy PDF robi [pyHanko](https://github.com/MatthiasValvekens/pyHanko): PAdES baseline B, SHA-256, rodzaj zobowiązania „proof of approval”, zapis przyrostowy.
- Grafika podpisu to HTML wydrukowany do PDF przez Chromium w tle, wstawiony jako wygląd pola podpisu.
- Linię podpisu znajdują `pdftotext -bbox` i `pdftoppm`: podpis staje nad tekstem kotwicy, może przeciąć linię jak atrament i kończy się pod najbliższym tekstem powyżej.
- XAdES-BES jest składany ręcznie w lxml (exclusive c14n, RSA-SHA256, SigningCertificate, ProofOfApproval) i sprawdzany przez `xmlsec1`.
- Aplikacja to SwiftUI nad CLI. Rozmawia z `podpisz --json`, podgląd rysuje tym samym kodem co prawdziwy podpis, a PIN trzyma w pamięci tylko na czas podpisywania, chyba że wybierzesz Touch ID.

## Rozwój

```bash
swift test     # atrapa CLI chodzi na Pythonie z scripts/install-cli.sh (albo ustaw PODPIS_PYTHON)
PODPIS_CLI=$PWD/Tools/fake-podpisz ~/Applications/Podpis.app/Contents/MacOS/Podpis
```

`Tools/fake-podpisz` udaje kartę (PIN `1234`, testowy certyfikat, błędy na życzenie przez `$FAKE_PODPIS_DIR/state.json`), więc aplikację rozwijasz bez czytnika. Gdy aplikacja działa z czymś innym niż `~/.local/bin/podpisz`, pokazuje plakietkę „Tryb testowy”. Dokumenty testowe robi `Tools/make-fixtures.py`.

## Prawo

Podpis nie jest powiązany z KIR (Krajowa Izba Rozliczeniowa S.A.) ani CryptoTech. Szafir to znak towarowy KIR. Sterownik karty należy do nich i nie jest częścią tego repozytorium. Potrzebujesz własnego certyfikatu kwalifikowanego i karty.

Oprogramowanie jest bez gwarancji (patrz LICENSE). Czytaj każdy dokument, zanim go podpiszesz.

## Licencja

MIT. Zrobione przez [Outofplace](https://outofplace.space).
