# -*- coding: utf-8 -*-
"""Backtest modeli ryzyka TSMA na historii z AuctionEngine (sqlite), zapis calib.json.

Uzycie:  python tests/backtest.py [sciezka_do_history_forever_*.sqlite]
Bez argumentu bierze najnowszy plik history_forever_*.sqlite z %APPDATA%\\AuctionEngine.
calib.json jest czytany przez AuctionEngine przy kazdym eksporcie i trafia do BlizzData.lua (calib = { zs, disp }).
"""
import glob
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import flow

DATA_DIR = os.path.join(os.environ.get("APPDATA", os.path.expanduser("~")), "AuctionEngine")
CALIB_PATH = os.path.join(DATA_DIR, "calib.json")


def main():
    if len(sys.argv) > 1:
        db = sys.argv[1]
    else:
        files = sorted(glob.glob(os.path.join(DATA_DIR, "history_forever_*.sqlite")), key=os.path.getmtime)
        if not files:
            print("Brak plikow history_forever_*.sqlite w", DATA_DIR)
            return 1
        db = files[-1]
    print("Baza:", db)
    calib, rep = flow.run_backtest(db)
    print("\n".join(rep))
    if "zs" in calib or "disp" in calib:
        os.makedirs(DATA_DIR, exist_ok=True)
        with open(CALIB_PATH, "w", encoding="utf-8") as f:
            json.dump(calib, f, indent=2)
        print("Zapisano", CALIB_PATH, "->", calib)
    else:
        print("Za malo danych, calib.json nie zapisany.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
