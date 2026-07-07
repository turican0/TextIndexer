# TextIndexer (Godot 4, Android)

Aplikace pro fulltextové indexování a čtení lokálních textových/webových
souborů (HTML/JS/CSS/TXT/MD/...) uložených v telefonu.

## Jak to funguje

1. **Nastavení** → tlačítko *Povolit přístup k úložišti* – vyžádá Android
   storage permission. *Vybrat složku* – otevře jednoduchý vlastní prohlížeč
   složek (Godot bohužel nemá vestavěný nativní "vyber složku" dialog pro
   Android bez pluginu – viz sekce Omezení níže). *Indexovat* – rekurzivně
   projde vybranou složku, ze všech podporovaných souborů odstraní HTML
   značky, `<script>`/`<style>` bloky i komentáře a zaindexuje čistá slova.
2. **Hlavní obrazovka** – vyhledávací pole, výsledky (název souboru + počet
   výskytů) seřazené sestupně podle četnosti, scrollovatelný seznam.
3. **Čtecí režim** – po kliknutí na výsledek se zobrazí očištěný text
   souboru, scrollovatelně, s tlačítkem *Zpět*.

Index i cesta ke složce se ukládají do `user://` (přežije restart appky).

## Nastavení exportu pro Android (v editoru)

`Project → Export → Android` – v sekci **Permissions** zaškrtni:

- `READ_EXTERNAL_STORAGE`
- `WRITE_EXTERNAL_STORAGE`
- `MANAGE_EXTERNAL_STORAGE`

Min SDK doporučuji 21+, cílový SDK podle aktuálních požadavků Google Play.

## Důležité omezení (Android scoped storage)

Od Androidu 10/11 platí tzv. *scoped storage* – běžné aplikace nemají bez
dalšího přístup k libovolné složce v úložišti, pouze ke svým vlastním
adresářům, pokud uživatel neudělí speciální "All files access" oprávnění
(`MANAGE_EXTERNAL_STORAGE`). Toto oprávnění se **neuděluje** přes běžný
`OS.request_permissions()` dialog, ale přes speciální stránku v Nastavení
telefonu, kterou čistý GDScript bez pluginu neumí sám otevřít.

Praktický dopad:
- Na starších Androidech (do verze 10) by mělo jít o čtení klasických
  `READ_EXTERNAL_STORAGE`/`WRITE_EXTERNAL_STORAGE` bez problémů.
- Na novějších Androidech pravděpodobně bude nutné ručně přejít do
  `Nastavení telefonu → Aplikace → TextIndexer → Oprávnění → Přístup ke
  všem souborům` a povolit to ručně (jednorázově).
- Pokud bys chtěl plnohodnotný nativní "vyber složku" dialog (Storage
  Access Framework) bez ručního povolování, řešením je Android plugin
  pro Godot (např. hledej "Godot Android SAF" / file picker pluginy na
  AssetLib) – to je ale nad rámec čistého GDScript řešení a vyžaduje
  vlastní build Android knihovny (.aar).

Vlastní prohlížeč složek v appce (`FolderBrowser.tscn`) funguje nad běžným
`DirAccess`, takže jakmile appka práva má, může procházet celé úložiště.

## Přizpůsobení

- `SKIP_EXTENSIONS` v `global/Indexer.gd` – přípony, které se přeskočí bez
  otevírání (obrázky, videa, archivy, binárky...). Vše ostatní se posoudí
  podle obsahu souboru (`_is_probably_text`) – takže se indexuje opravdu
  cokoliv textového: html, gdscript, cs, py, md, txt, atd., ne jen webové
  přípony.
- `MAX_FILE_SIZE_BYTES` – soubory větší než limit (výchozí 4 MB) se přeskočí
  kvůli výkonu na mobilu.
- Hledání je **podřetězcové** (substring) přes všechna zaindexovaná slova -
  např. "index" najde i "indexovat", "indexed" atd. - a zároveň "OR" napříč
  víc zadanými slovy, se sečteným skóre četnosti. Kvůli tomu, že se teď
  prochází celá slovní zásoba (ne jen hash lookup), je vyhledávání při psaní
  zpožděné o 0.25 s (debounce), ať to na telefonu nesekne.
- Pokud chceš přísné "AND" (musí obsahovat všechna zadaná slova), stačí
  upravit funkci `search()` v `Indexer.gd`.
