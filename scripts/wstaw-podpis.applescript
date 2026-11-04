-- Wstaw podpis: a droplet for PDFs. It runs `podpisz wyglad --json` on the dropped files: the art of
-- your signature goes on your signature lines, before you sign with a tool that signs invisibly.
-- The results land next to the originals (name-do-podpisu.pdf); a notification says how many and
-- Finder shows them. Built by scripts/build-droplet.sh.
use AppleScript version "2.7"
use framework "Foundation"
use scripting additions

property appName : "Wstaw podpis"

on run
	display dialog "Upuść pliki PDF na ikonę „Wstaw podpis”." & return & return & ¬
		"Na każdej linii podpisu z Twoim imieniem i nazwiskiem stanie grafika Twojego podpisu. Wynik ląduje obok oryginału jako „…-do-podpisu.pdf”. Ten plik podpisujesz potem swoim narzędziem do podpisu." & return & return & ¬
		"Gdy ostatni podpis w pliku jest Twój, zostanie odcięty: podpiszesz jeszcze raz, już z grafiką." buttons {"OK"} default button "OK" with title appName
end run

on open dropped
	set pdfs to {}
	repeat with f in dropped
		set p to POSIX path of f
		if p ends with ".pdf" then set end of pdfs to p
	end repeat
	if pdfs is {} then
		display notification "Upuść pliki PDF." with title appName
		return
	end if

	-- Finder starts apps with a bare PATH; the CLI needs poppler from Homebrew
	set cmd to "export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin; " & ¬
		quoted form of ((POSIX path of (path to home folder)) & ".local/bin/podpisz") & " wyglad --json"
	repeat with p in pdfs
		set cmd to cmd & " " & quoted form of (p as text)
	end repeat
	-- the exit code is in the JSON as well; `true` keeps do shell script from turning it into an error
	set out to do shell script cmd & " 2>/dev/null; true"

	set res to missing value
	if out is not "" then
		set jsonData to (current application's NSString's stringWithString:out)'s dataUsingEncoding:(current application's NSUTF8StringEncoding)
		set res to current application's NSJSONSerialization's JSONObjectWithData:jsonData options:0 |error|:(missing value)
	end if
	if res is missing value then
		display alert appName message "Nie widzę narzędzia podpisz albo nie odpowiedziało. Zainstaluj je: scripts/install-cli.sh w repozytorium Podpis." as critical
		return
	end if
	set res to res as record
	try
		set results to |pliki| of res
	on error
		display alert appName message (|blad| of res) as critical
		return
	end try

	set done to {}
	set problems to {}
	set lineCount to 0
	set cutCount to 0
	repeat with w in results
		set w to contents of w
		if |ok| of w then
			set end of done to |plik| of w
			set lineCount to lineCount + (count of (|miejsca| of w))
			if |cofniety| of w is not missing value then set cutCount to cutCount + 1
		else
			set end of problems to (my baseName(|zrodlo| of w)) & ": " & (|blad| of w)
		end if
	end repeat

	if done is not {} then
		set msg to "Gotowe: " & (count of done) & " z " & (count of results) & " (linii podpisu: " & lineCount & ")."
		if cutCount > 0 then set msg to msg & " Odcięto Twój wcześniejszy podpis w " & cutCount & ": podpisz jeszcze raz."
		display notification msg with title appName subtitle (my dirName(item 1 of done))
		set reveal to "open -R"
		repeat with p in done
			set reveal to reveal & " " & quoted form of (p as text)
		end repeat
		do shell script reveal
	end if
	if problems is not {} then
		set AppleScript's text item delimiters to return
		set report to problems as text
		set AppleScript's text item delimiters to ""
		display alert appName message "Nie wszystko się udało:" & return & return & report as warning
	end if
end open

on baseName(p)
	set AppleScript's text item delimiters to "/"
	set n to last text item of (p as text)
	set AppleScript's text item delimiters to ""
	return n
end baseName

on dirName(p)
	set AppleScript's text item delimiters to "/"
	set parts to text items of (p as text)
	set d to (items 1 thru -2 of parts) as text
	set AppleScript's text item delimiters to ""
	return d
end dirName
