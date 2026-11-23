# TSMA (TsmAnalize + AuctionEngine)

Addon do World of Warcraft (WoW Forever) analizujacy oplacalnosc handlu na podstawie TSM, plus aplikacja desktopowa AuctionEngine (Python), ktora pobiera dane z Blizzard AH i generuje `BlizzData.lua` oraz `Import.lua`.

## Struktura
- `TsmAnalize/` - addon (Lua). Kolejnosc ladowania w `TsmAnalize.toc`.
- `AuctionEngine.py`, `run.bat`, `build_exe.bat` - silnik Blizzard (tylko Forever, regiony eu / us).
- `tests/` - smoke test addonu na atrapie API (`run_tests.py` + `harness.lua`) oraz testy silnika (`test_engine.py`).

## Instalacja
1. Skopiuj folder `TsmAnalize` do `...\_forever_\Interface\AddOns\`.
2. Uruchom `run.bat` (instaluje `requests`), wpisz Client ID / Secret z https://develop.battle.net, region (`eu` / `us`), ruleset i dom aukcyjny (np. Horde - 113), folder addonu (przycisk "Wykryj") i kliknij "Pobierz teraz" albo "Start auto-odswiezania".
3. AuctionEngine sam zapisuje `BlizzData.lua` i `Import.lua` w folderze addonu i dopisuje je do `.toc` (`ensure_toc`). Forever nie uzywa Realm ID ani connected-realm.
4. W grze `/reload` po kazdym eksporcie. Komenda: `/tsma blizz`.

## Sekrety
Client Secret jest zapisywany w `%APPDATA%\AuctionEngine\config.json`. Nie wrzucaj `config.json` do repozytorium (jest w `.gitignore`).

## Testy
```
pip install lupa pytest requests
python tests/run_tests.py TsmAnalize
pytest tests
```
Test addonu nie zastepuje gry: nazwy funkcji WoW sprawdzisz dopiero `/tsma errors` w kliencie.
