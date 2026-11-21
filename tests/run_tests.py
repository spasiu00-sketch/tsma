"""Smoke test addonu TsmAnalize na atrapie API WoW (bez gry).

Uzycie:  pip install lupa   a potem   python tests/run_tests.py [sciezka_do_folderu_TsmAnalize]
Sprawdza skladnie (Lua 5.1) i uruchamia glowne sciezki addonu; linie zaczynajace sie od FAIL / ERROR oznaczaja blad.
To NIE jest prawdziwy klient WoW - nazwy funkcji gry nadal sprawdza dopiero gra (/tsma selftest, /tsma errors).
"""
import os, sys
from lupa import lua51

here = os.path.dirname(os.path.abspath(__file__))
addon = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "..", "TsmAnalize")
addon = os.path.abspath(addon)

lua = lua51.LuaRuntime(unpack_returned_tuples=True)
loadstr = lua.eval("function(src, name) return loadstring(src, name) end")

bad = 0
for f in sorted(os.listdir(addon)):
    if f.endswith(".lua"):
        chunk = loadstr(open(os.path.join(addon, f), encoding="utf-8").read(), "@" + f)
        if isinstance(chunk, tuple):
            print("SYNTAX ERROR", f, chunk[1]); bad += 1

harness = loadstr(open(os.path.join(here, "harness.lua"), encoding="utf-8").read(), "@harness")
report = harness(addon)
for line in report.split("\n"):
    if line.startswith(("FAIL", "LOAD ERROR", "EVENT ERROR", "TIMER ERROR", "ns.errors")):
        bad += 1
    print(line[:300])
print("\nWYNIK:", "BLEDY: %d" % bad if bad else "OK - brak bledow w atrapie")
sys.exit(1 if bad else 0)
