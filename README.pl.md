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
- **Wygląd dla podpisu innym narzędziem.** `podpisz wyglad` i aplikacja Wstaw podpis stawiają ten sam wygląd na Twoich liniach podpisu, zanim podpiszesz plik narzędziem, które składa podpis niewidoczny. Bez karty i bez PIN-u.

## Czego nie robi

- Bez znaczników czasu (bez PAdES-T i XAdES-T), bez formatów długoterminowych, bez plików PKCS#7 (.sig). Szafir2 ma znaczniki czasu, XAdES-T/C/A i PKCS#7.
- `podpisz sprawdz` sprawdza, czy podpis jest nienaruszony i obejmuje cały plik. Nie sprawdza łańcucha zaufania. Do formalnej weryfikacji służą oficjalne walidatory KIR albo UE.
- Przetestowana jest tylko karta Szafir z KIR (token „PKI Token 2 (QSCD)”, czytnik ACS ACR40T). Karty innych dostawców wymagają ich sterownika PKCS#11 i etykiety tokenu (patrz Ustawienia). Mogą działać, ale nikt jeszcze nie próbował.

## Wymagania

- macOS 26 lub nowszy. Testowane na macOS 27.0.1, Apple silicon.
- **Zainstalowany Szafir2 z KIR.** Podpis nie zawiera sterownika karty. Korzysta z `libPKCS11Graphite.dylib` (CryptoTech), uniwersalnej biblioteki z paczki `Szafir2.app`. Szafir2 zostaje na dysku tylko dla tego pliku.
- Python 3.11 lub nowszy, `brew install poppler libxmlsec1` (`xmlsec1` tylko do podpisów XML).
- Google Chrome, Chromium, Brave albo Edge: rysują grafikę podpisu w tle.
- Xcode 26 do zbudowania aplikacji.

## Instalacja

```bash
git clone https://github.com/outof-place/podpis.git
cd podpis
scripts/install-cli.sh      # podpisz: venv w ~/.local/share/podpis, skrót w ~/.local/bin
scripts/build-app.sh        # Podpis.app do /Applications
scripts/build-droplet.sh    # Wstaw podpis.app do /Applications (wygląd dla podpisu innym narzędziem)
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
podpisz wyglad umowa.pdf --nad "Jan Kowalski"    # wygląd podpisu przed podpisem innym narzędziem
```

PIN: domyślnie natywne okienko macOS albo `--pin-stdin`. Nigdy nie trafia na dysk ani na ekran. Po złym PIN-ie `podpisz` przerywa i nie próbuje ponownie. Przy ostatniej próbie odmawia podpisu bez `--wymus`.

## Wygląd dla podpisu innym narzędziem

Niektóre narzędzia (na przykład podpis kwalifikowany EuroCert składany przez iText) dają tylko podpis niewidoczny. `podpisz wyglad` wstawia przed takim podpisem ten sam wygląd, który rysuje `podpisz pdf`: Twój odręczny podpis z `sygnatura.png` i nad nim drobne „Kwalifikowany podpis elektroniczny · data”. Potem podpisujesz plik swoim narzędziem, a podpis obejmuje także wygląd. Odwrotnie się nie da: cokolwiek dopisane po podpisie wychodzi poza jego zakres i walidator to pokaże.

```bash
podpisz wyglad umowa.pdf aneks.pdf                         # obok oryginału: umowa-do-podpisu.pdf
podpisz wyglad *.pdf --nad "Jan Kowalski" --out-dir do-podpisu
```

- **Gdzie.** Na każdej linii podpisu z Twoim imieniem i nazwiskiem (`--nad`, domyślnie `imie` z `config.json`) na każdej stronie, więc także dwa razy, gdy podpisujesz za spółkę i osobiście, i także w załącznikach dołączonych do pliku. Linia podpisu to linia z podkreśleń albo kropek albo narysowana kreska, najwyżej 30 pt nad nazwiskiem i nad nim, a w wierszu przed nazwiskiem może stać tylko etykieta z dwukropkiem („Name:”). Nazwisko w treści (strony umowy, definicje, tabela) nie ma nad sobą linii, więc tam wygląd nie trafia. `--strona` ogranicza go do jednej strony.
- **Jak leży.** Na linii, jak atrament, z dala od etykiet („By:”). Pieczęć na linii omija: gdy obok niej brakuje miejsca, wygląd robi się mniejszy (do 60%), a dopiero gdy i to nie wystarcza, leży na niej w pełnym rozmiarze. Gdy tuż nad linią stoi tekst, wygląd staje obok linii, równo z podpisem, który już jest na stronie. Jest rysowany z mieszaniem Multiply, więc to, nad czym leży, prześwituje jak spod atramentu.
- **Wcześniejsze podpisy zostają nienaruszone.** Wygląd to zablokowana adnotacja /Stamp (drukowana, tylko do odczytu) w zapisie przyrostowym: plik wejściowy zostaje bajt w bajt na początku wyniku, a treść stron się nie zmienia. Zanim cokolwiek zapisze, `wyglad` sprawdza każdy wcześniejszy podpis w pyHanko i przerywa, gdy któryś nie jest nienaruszony albo gdy po nim doszło coś poza wyglądem. W `--json` `zmiany_po` to ocena domyślnej polityki pyHanko, która każdą adnotację dodaną po podpisie nazywa OTHER (nie ma reguł dla adnotacji), a `zmiany_po_wyglad` to ta sama polityka z regułą dla samych adnotacji /Stamp: ANNOTATIONS znaczy, że po podpisie doszedł tylko wygląd.
- **Cofnięcie Twojego podpisu.** Gdy ostatni podpis w pliku jest Twój (nazwa z certyfikatu równa `--nad`) i obejmuje cały plik, `wyglad` odcina go razem z jego zapisem przyrostowym. Zostaje plik bajt w bajt taki jak przed tym podpisem, potem dochodzi wygląd, a Ty podpisujesz jeszcze raz. Cudzego podpisu nie odcina nigdy. `--bez-cofania` wyłącza cofanie: wtedy Twój podpis przestaje obejmować cały plik i `wyglad` to zgłasza.
- **Bez karty.** `wyglad` nie ładuje sterownika karty, więc działa bez Szafira2 i bez python-pkcs11. Data nad podpisem to dzień wstawienia wyglądu (`--data` zmienia ją), bo godziny podpisu jeszcze nie znamy. Strony obrócone pomija.
- **Wstaw podpis.app.** `scripts/build-droplet.sh` buduje w `/Applications` (w `~/Applications`, gdy tam nie można pisać) aplikację bez uprawnień administratora. Upuszczasz na nią pliki PDF: woła `podpisz wyglad --json`, pokazuje powiadomienie z wynikiem i odsłania pliki w Finderze.

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
~/.local/share/podpis/venv/bin/python -m unittest discover -s Tests/cli -v   # podpisz wyglad
PODPIS_CLI=$PWD/Tools/fake-podpisz /Applications/Podpis.app/Contents/MacOS/Podpis
```

`Tools/fake-podpisz` udaje kartę (PIN `1234`, testowy certyfikat, błędy na życzenie przez `$FAKE_PODPIS_DIR/state.json`), więc aplikację rozwijasz bez czytnika. Gdy aplikacja działa z czymś innym niż `~/.local/bin/podpisz`, pokazuje plakietkę „Tryb testowy”. Dokumenty testowe robi `Tools/make-fixtures.py`.

## Prawo

Podpis nie jest powiązany z KIR (Krajowa Izba Rozliczeniowa S.A.) ani CryptoTech. Szafir to znak towarowy KIR. Sterownik karty należy do nich i nie jest częścią tego repozytorium. Potrzebujesz własnego certyfikatu kwalifikowanego i karty.

Oprogramowanie jest bez gwarancji (patrz LICENSE). Czytaj każdy dokument, zanim go podpiszesz.

## Licencja

MIT. Zrobione przez [Outofplace](https://outofplace.space).
