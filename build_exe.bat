@echo off
cd /d "%~dp0"
python -m pip install -r requirements.txt pyinstaller
pyinstaller --onefile --noconsole --name AuctionEngine AuctionEngine.py
echo.
echo Gotowe: dist\AuctionEngine.exe
pause
