1) Wypakuj AuctionEngine gdziekolwiek. W folderze dodatku TsmAnalize wgraj BlizzData.lua i Blizz.lua
   (Import.lua zostanie nadpisany przez silnik).
2) W TsmAnalize.toc po linii "Import.lua" dopisz dwie linie:
       BlizzData.lua
       Blizz.lua
3) run.bat -> wpisz Client ID/Secret (https://develop.battle.net), region, Realm ID, namespace,
   folder dodatku (np. ...\_classic_\Interface\AddOns\TsmAnalize) -> Zapisz -> START.
4) W grze /reload po kazdym eksporcie. Komenda: /tsma blizz
