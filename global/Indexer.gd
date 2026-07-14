extends Node

# ---------------------------------------------------------------------------
# Indexer - autoload singleton
# Zajišťuje: výběr/uložení cesty ke složce, rekurzivní indexaci textových
# souborů (s odstraněním HTML/JS), fulltextové hledání a čtení souboru
# v "reader" režimu (opět bez HTML/JS značek).
# ---------------------------------------------------------------------------

const SETTINGS_PATH := "user://settings.json"

# Index, rozpracovaný stav a seznam souborů k indexaci se ukládají binárně
# (Variant) + gzip komprimovaně, ne jako čitelný JSON text. Číselné hodnoty
# (počty výskytů, file_id) se tak ukládají jako čísla, ne jako text, a gzip
# navrch odstraní opakující se vzory ve struktuře - výsledné soubory jsou
# výrazně menší a rychlejší na zápis/čtení než ekvivalentní JSON, což je
# důležité hlavně u indexu, který bez téhle úpravy dokázal appku shazovat
# kvůli nedostatku paměti.
const INDEX_PATH := "user://index.bin"
const INDEXING_STATE_PATH := "user://indexing_state.bin"  # rozpracovaný (nedokončený) běh indexace - jen to, co se mění
const INDEXING_FILELIST_PATH := "user://indexing_filelist.bin"  # seznam souborů k indexaci - uloží se jednou, neměnní se

# Staré (čitelné JSON) cesty z předchozí verze appky - používají se JEN pro
# jednorázovou migraci hlavního indexu při startu (viz _migrate_legacy_index),
# ať uživatel nemusí po aktualizaci indexovat znovu od nuly. Rozpracovaný stav
# a filelist se nemigrují - jsou to jen dočasná data pro navázání přerušené
# indexace, takže při aktualizaci appky uprostřed indexování se v nejhorším
# případě jen znovu spustí od začátku, což je v pořádku.
const INDEX_PATH_LEGACY_JSON := "user://index.json"

# Bílá listina - indexují se JEN soubory s těmito příponami. Vše ostatní se
# přeskočí rovnou bez otevírání.
const ALLOWED_EXTENSIONS := [
	"htm", "html", "shtml", "php", "txt"
]

# Soubory větší než tohle se přeskočí (kvůli výkonu na mobilu).
const MAX_FILE_SIZE_BYTES := 4 * 1024 * 1024  # 4 MB

# Soubory menší než tohle se taky přeskočí - obvykle jde o prázdné/skoro
# prázdné soubory (přesměrování, zápatí, placeholdery...), které nemají
# smysluplný obsah k vyhledávání, ale v indexu by zbytečně přidávaly
# záznamy navíc.
const MIN_FILE_SIZE_BYTES := 20 * 1024  # 20 KB

# Mapa pro odstranění diakritiky (čeština/slovenština + běžné latinské akcenty),
# aby hledání fungovalo bez ohledu na háčky/čárky.
const DIACRITICS_MAP := {
	"á": "a", "ä": "a", "à": "a", "â": "a", "ã": "a", "å": "a",
	"č": "c", "ć": "c", "ç": "c",
	"ď": "d", "đ": "d",
	"é": "e", "ě": "e", "è": "e", "ê": "e", "ë": "e",
	"í": "i", "ì": "i", "î": "i", "ï": "i",
	"ľ": "l", "ĺ": "l", "ł": "l",
	"ň": "n", "ń": "n", "ñ": "n",
	"ó": "o", "ô": "o", "ò": "o", "ö": "o", "õ": "o", "ő": "o",
	"ř": "r", "ŕ": "r",
	"š": "s", "ś": "s",
	"ť": "t",
	"ú": "u", "ů": "u", "ù": "u", "û": "u", "ü": "u", "ű": "u",
	"ý": "y", "ÿ": "y",
	"ž": "z", "ź": "z", "ż": "z"
}


func strip_diacritics(text: String) -> String:
	var result := ""
	for i in range(text.length()):
		var ch := text[i]
		result += DIACRITICS_MAP.get(ch, ch)
	return result


# Nejčastější česká/slovenská "gramatická" slova (spojky, předložky, zájmena,
# tvary "být" atd.) - v naprosté většině textových souborů se vyskytují
# skoro na každé stránce, takže mají v indexu obrovské seznamy souborů, ale
# k samotnému hledání konkrétního obsahu prakticky nepomáhají. Přeskočením
# se výrazně zmenší jak počet unikátních položek v indexu, tak hlavně délka
# seznamů u těch pár slov, co skutečně zůstanou. Klíče jsou už bez diakritiky
# (stejně jako výstup _tokenize), aby seděly na to, co se reálně porovnává.
# Seznam je záměrně jen orientační/rozšiřitelný, ne lingvisticky úplný.
const STOPWORDS := {
	"a": true, "i": true, "o": true, "u": true, "k": true, "s": true, "v": true, "z": true,
	"se": true, "si": true, "je": true, "na": true, "do": true, "za": true, "po": true,
	"ze": true, "ale": true, "nebo": true, "jako": true, "tak": true, "uz": true,
	"ted": true, "ktery": true, "ktera": true, "ktere": true, "tento": true, "tato": true,
	"toto": true, "tyto": true, "jsem": true, "jsi": true, "jsme": true, "jste": true,
	"jsou": true, "byl": true, "byla": true, "bylo": true, "byli": true, "bude": true,
	"budou": true, "ma": true, "maji": true, "ani": true, "aby": true, "kdyz": true,
	"protoze": true, "tim": true, "tomu": true, "jeho": true, "jeji": true, "jejich": true,
	"muj": true, "tvuj": true, "nas": true, "vas": true, "ho": true, "ji": true, "mu": true,
	"tu": true, "tam": true, "tady": true, "ten": true, "ta": true, "to": true, "ti": true,
	"ty": true, "on": true, "ona": true, "ono": true, "oni": true, "ony": true,
	"my": true, "vy": true, "ja": true, "at": true,
}

var selected_folder: String = ""
var selected_folder_raw: String = ""  # původní cesta/URI vrácená systémovým výběrem, před převodem
var reader_font_size: int = 36
# slovo -> PackedInt32Array dvojic [file_id, pocet, file_id, pocet, ...].
# Proč PackedInt32Array a ne vnořený Dictionary{file_id: pocet}: Godot
# Dictionary má na KAŽDOU instanci (i s 2-3 položkami) poměrně velkou pevnou
# režii (hashovací tabulka, buckety). Při desítkách/stovkách tisíc unikátních
# slov to znamenalo stovky tisíc samostatných Dictionary objektů jen kvůli
# téhle režii navíc k datům samotným - a to byl hlavní zdroj paměťového
# tlaku (appka padala i po přechodu na binární uložení, protože ten problém
# je za BĚHU v paměti, ne jen na disku). PackedInt32Array ukládá čísla jako
# hutné pole bez téhle režie na položku, takže je výrazně úspornější.
var index_data: Dictionary = {}
var indexed_files: Array = []        # seznam všech zaindexovaných souborů
var indexed_titles: Array = []       # titulek stránky (<title>) pro každý soubor - stejný index jako indexed_files, "" když soubor titulek nemá
var last_index_time: int = 0         # unix čas poslední ÚSPĚŠNĚ dokončené indexace (0 = nikdy)
var current_reader_path: String = "" # cesta k souboru, který se má otevřít v Readeru

# Adresáře, které se při procházení úplně přeskočí (obvykle objemné a
# nezajímavé pro fulltextové hledání - cache, verzovací systém, závislosti...).
const SKIP_DIRECTORIES := [".git", ".import", ".godot", ".venv", "node_modules", "__pycache__", ".vs", ".vscode"]

var is_indexing: bool = false
var indexing_progress: float = 0.0
var indexing_status_text: String = ""

signal indexing_finished
signal indexing_progress_changed(progress: float, status: String)

# Předkompilované regexy (viz _ready) - znovupoužité pro každý soubor.
var _re_word := RegEx.new()
var _re_comment := RegEx.new()
var _re_tag := RegEx.new()
var _re_ws := RegEx.new()
var _re_nl := RegEx.new()
var _re_title := RegEx.new()

func _ready() -> void:
	load_settings()
	load_index()

	# Regulární výrazy kompilujeme jen JEDNOU při startu, ne pokaždé pro
	# každý soubor - kompilace regexu je řádově dražší než jeho použití,
	# a u velkého množství souborů to byl citelný podíl celkového času.
	_re_word.compile("[\\p{L}\\p{N}_]+")
	_re_comment.compile("<!--[\\s\\S]*?-->")
	_re_tag.compile("<[^>]*>")
	_re_ws.compile("[ \\t]+")
	_re_nl.compile("\\n{3,}")
	_re_title.compile("(?i)<title[^>]*>([\\s\\S]*?)</title>")

	# Přímé, za-běhu nastavení orientace - nezávisí na tom, co (ne)obsahuje
	# vygenerovaný AndroidManifest.xml, takže by mělo fungovat i kdyby export
	# šablona orientaci z project.godot ze záhadných důvodů neaplikovala.
	if OS.get_name() == "Android":
		DisplayServer.screen_set_orientation(DisplayServer.SCREEN_SENSOR_PORTRAIT)


# ---------------------------------------------------------------------------
# Android oprávnění
# ---------------------------------------------------------------------------

func request_storage_permission() -> void:
	if OS.get_name() == "Android":
		OS.request_permissions()

func has_storage_permission() -> bool:
	if OS.get_name() != "Android":
		return true
	var granted := OS.get_granted_permissions()
	for p in granted:
		if p.findn("READ_EXTERNAL_STORAGE") != -1 or p.findn("MANAGE_EXTERNAL_STORAGE") != -1:
			return true
	return false


# ---------------------------------------------------------------------------
# Android SAF (content://) cesty -> reálná cesta v souborovém systému
# ---------------------------------------------------------------------------
# Nativní výběr složky na Androidu vrací "content://" URI (Storage Access
# Framework), se kterým DirAccess/FileAccess v Godotu zatím pořádně neumí
# pracovat. Pro běžné "primary" externí úložiště (/storage/emulated/0/...)
# ale dokážeme z té URI odvodit skutečnou cestu.

func resolve_folder_path(raw_path: String) -> String:
	if not raw_path.begins_with("content://"):
		return raw_path

	var marker := "/tree/"
	var idx := raw_path.find(marker)
	if idx == -1:
		return raw_path

	var encoded_doc_id := raw_path.substr(idx + marker.length())
	var doc_id := encoded_doc_id.uri_decode()

	var colon_idx := doc_id.find(":")
	if colon_idx == -1:
		return raw_path

	var volume := doc_id.substr(0, colon_idx)
	var sub_path := doc_id.substr(colon_idx + 1)

	if volume == "primary":
		return "/storage/emulated/0/" + sub_path
	else:
		# Vyměnitelné úložiště (SD karta) - volume je jeho ID.
		return "/storage/" + volume + "/" + sub_path


# Vrátí čitelný diagnostický text o tom, jestli je zadaná složka reálně
# čitelná - kolik položek v ní DirAccess vidí, jestli DirAccess.open() vůbec
# uspěl, a navíc zkusí reálně PŘEČÍST obsah prvního nalezeného souboru (ne
# jen ho vypsat) - aby bylo jasné, jestli je problém v listování adresáře,
# nebo až ve čtení konkrétního souboru. Zobrazujeme přímo v appce, aby se
# dalo ladit i bez adb/logcatu.
func diagnose_path(path: String) -> String:
	var lines: Array = []
	if selected_folder_raw != "" and selected_folder_raw != path:
		lines.append("Cesta z výběru (surová): %s" % selected_folder_raw)
	lines.append("Cesta (po převodu): %s" % path)

	if OS.get_name() == "Android":
		lines.append("Android verze SDK: %s" % OS.get_version())
		var granted := OS.get_granted_permissions()
		lines.append("Udělená oprávnění (%d): %s" % [granted.size(), (", ".join(granted) if granted.size() > 0 else "žádná")])
		lines.append("has_storage_permission(): %s" % ("ANO" if has_storage_permission() else "NE"))

	# --- 1) Otevření adresáře ---
	var dir := DirAccess.open(path)
	if dir == null:
		var err := DirAccess.get_open_error()
		lines.append("DirAccess.open() SELHALO: %s (kód %d)" % [error_string(err), err])
		lines.append("-> Adresář se nepodařilo ani otevřít pro čtení. Nejčastější příčina: chybějící 'Přístup ke všem souborům' (MANAGE_EXTERNAL_STORAGE).")
		return "\n".join(lines)

	lines.append("DirAccess.open() OK.")

	# --- 2) Výpis obsahu ---
	dir.list_dir_begin()
	var name := dir.get_next()
	var file_count := 0
	var dir_count := 0
	var sample: Array = []
	while name != "":
		if name != "." and name != "..":
			if dir.current_is_dir():
				dir_count += 1
			else:
				file_count += 1
			if sample.size() < 5:
				sample.append(name)
		name = dir.get_next()
	dir.list_dir_end()

	lines.append("Výpis adresáře (jen 1. úroveň): podsložek %d, souborů %d." % [dir_count, file_count])
	if sample.size() > 0:
		lines.append("Ukázka položek: " + ", ".join(sample))
	elif dir_count == 0 and file_count == 0:
		lines.append("-> DirAccess adresář otevřel, ale nevidí v něm ŽÁDNÉ položky (typické pro omezený přístup bez MANAGE_EXTERNAL_STORAGE).")

	# --- 3) Rekurzivní kontrola - stejně jako reálné indexování prochází
	# i podsložky, takže i diagnostika se musí podívat hlouběji, ne jen na
	# první úroveň, aby "0 souborů" na 1. úrovni nevypadalo jako chyba.
	var deep := {"files": 0, "dirs": 0, "sample": []}
	_diag_scan_recursive(path, deep, 0)
	lines.append("Rekurzivní průzkum celého stromu: podsložek %d, souborů celkem %d." % [deep["dirs"], deep["files"]])
	if deep["sample"].size() > 0:
		lines.append("Nalezené soubory (ukázka): " + ", ".join(deep["sample"]))

	var first_file_path: String = deep["sample"][0] if deep["sample"].size() > 0 else ""

	# --- 4) Reálný pokus přečíst konkrétní soubor (klidně z hloubky stromu) ---
	if first_file_path != "":
		lines.append("Zkouším přečíst: %s" % first_file_path.get_file())
		var f := FileAccess.open(first_file_path, FileAccess.READ)
		if f == null:
			var ferr := FileAccess.get_open_error()
			lines.append("FileAccess.open() SELHALO: %s (kód %d)" % [error_string(ferr), ferr])
			lines.append("-> Adresář se dá vylistovat, ale SOUBORY uvnitř se číst nedají. Skoro jistě chybí MANAGE_EXTERNAL_STORAGE.")
		else:
			var len := f.get_length()
			var sample_bytes := f.get_buffer(min(len, 64))
			f.close()
			lines.append("FileAccess.open() OK, velikost %d B, prvních pár bajtů: %s" % [len, sample_bytes.get_string_from_utf8().left(40)])
	elif deep["dirs"] > 0:
		lines.append("-> V celém stromu se nenašel ani jeden soubor (jen podsložky) - buď je opravdu prázdný, nebo hlubší podsložky nejdou otevřít.")

	return "\n".join(lines)


# Pomocná rekurzivní funkce pro diagnostiku - kopíruje logiku skutečného
# indexování (_collect_files), ale sbírá počty a ukázky pro zobrazení,
# místo aby rovnou indexovala. Omezeno hloubkou a počtem položek, aby
# diagnostika nezamrzla na obřím stromu složek.
func _diag_scan_recursive(path: String, out: Dictionary, depth: int) -> void:
	if depth > 6 or out["files"] + out["dirs"] > 500:
		return
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name != "." and name != "..":
			var full_path := path.path_join(name)
			if dir.current_is_dir():
				out["dirs"] += 1
				if not (name in SKIP_DIRECTORIES):
					_diag_scan_recursive(full_path, out, depth + 1)
			else:
				out["files"] += 1
				if out["sample"].size() < 5:
					out["sample"].append(full_path)
		name = dir.get_next()
	dir.list_dir_end()


# ---------------------------------------------------------------------------
# Ukládání nastavení a indexu do user:// (perzistentní úložiště appky)
# ---------------------------------------------------------------------------

func save_settings() -> void:
	_write_json_atomic(SETTINGS_PATH, {"folder": selected_folder, "reader_font_size": reader_font_size})

func load_settings() -> void:
	if not FileAccess.file_exists(SETTINGS_PATH):
		return
	var f := FileAccess.open(SETTINGS_PATH, FileAccess.READ)
	if f == null:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) == TYPE_DICTIONARY and parsed.has("folder"):
		selected_folder = resolve_folder_path(parsed["folder"])
	if typeof(parsed) == TYPE_DICTIONARY and parsed.has("reader_font_size"):
		reader_font_size = int(parsed["reader_font_size"])

# Verze formátu indexu - ponechána i v binárním formátu pro budoucí snazší
# rozlišení nekompatibilních dat. Verze 5 = přidán seznam "titles" (titulek
# stránky <title> pro každý soubor, viz indexed_titles). Verze 4 = hodnota
# index_data[slovo] je PackedInt32Array párů [file_id, pocet] (dřív to byl
# vnořený Dictionary, co měl na mobilu příliš velkou paměťovou režii při
# stovkách tisíc slov).
const INDEX_FORMAT_VERSION := 5

func save_index() -> void:
	_write_var_compressed(INDEX_PATH, {
		"version": INDEX_FORMAT_VERSION,
		"words": index_data,
		"files": indexed_files,
		"titles": indexed_titles,
		"time": last_index_time,
	})

func load_index() -> void:
	var parsed = _read_var_compressed(INDEX_PATH)
	if typeof(parsed) == TYPE_DICTIONARY and parsed.has("words"):
		index_data = parsed["words"]
		indexed_files = parsed.get("files", [])
		indexed_titles = parsed.get("titles", [])
		# Index uložený ještě appkou bez titulků - doplníme prázdné položky,
		# ať indexed_titles má stejnou délku jako indexed_files a indexování
		# podle file_id nikde nespadne na chybějící index pole.
		while indexed_titles.size() < indexed_files.size():
			indexed_titles.append("")
		last_index_time = int(parsed.get("time", 0))
		_sorted_words_dirty = true
		return

	# Nový binární index nenalezen - zkusit převést starší JSON formát
	# (buď úplně starý s plnou cestou u každého slova, nebo mezitímní
	# verzi 2 s file_id uloženým jako string), pokud existuje.
	_migrate_legacy_index()
	_sorted_words_dirty = true


# Převede starý čitelný JSON index (index.json) na nový binární formát a
# rovnou ho uloží. Zvládá obě starší varianty:
#   - verze 1 (nebo bez verze): index_data["slovo"] = {"cesta": pocet, ...}
#   - verze 2/3: index_data["slovo"] = {"file_id_jako_string_nebo_int": pocet, ...}
#     + samostatné pole "files" s cestami (file_id = pozice v poli)
# V obou případech výsledek je totéž: index_data["slovo"] = PackedInt32Array
# párů [file_id, pocet, file_id, pocet, ...] (viz komentář u proměnné
# index_data výše). Po úspěšném převodu starý soubor smaže, ať uživatel
# nemusí po aktualizaci appky indexovat znovu od nuly.
func _migrate_legacy_index() -> bool:
	if not FileAccess.file_exists(INDEX_PATH_LEGACY_JSON):
		return false
	var f := FileAccess.open(INDEX_PATH_LEGACY_JSON, FileAccess.READ)
	if f == null:
		return false
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		return false

	var legacy_version := int(parsed.get("version", 1))
	var old_words: Dictionary = parsed.get("words", parsed)  # fallback pro formát bez obálky
	var old_files: Array = parsed.get("files", [])
	last_index_time = int(parsed.get("time", 0))

	index_data.clear()
	indexed_files.clear()
	indexed_titles.clear()

	if legacy_version >= 2:
		# file_id už existuje (jako string nebo int klíč) - jen převedeme
		# vnořený Dictionary na plochý PackedInt32Array párů.
		indexed_files = old_files
		for word in old_words.keys():
			var files_dict: Dictionary = old_words[word]
			var pairs := PackedInt32Array()
			for id_key in files_dict.keys():
				pairs.append(int(id_key))
				pairs.append(int(files_dict[id_key]))
			index_data[word] = pairs
	else:
		# Nejstarší formát - klíčem byla přímo cesta k souboru, potřebujeme
		# jí teprve přidělit file_id (a zajistit, že se stejná cesta napříč
		# různými slovy namapuje na stejné id).
		var file_id_by_path: Dictionary = {}
		for word in old_words.keys():
			var files_dict: Dictionary = old_words[word]
			var pairs := PackedInt32Array()
			for path in files_dict.keys():
				var fid: int
				if file_id_by_path.has(path):
					fid = file_id_by_path[path]
				else:
					fid = indexed_files.size()
					indexed_files.append(str(path))
					file_id_by_path[path] = fid
				pairs.append(fid)
				pairs.append(int(files_dict[path]))
			index_data[word] = pairs

	# Starý formát titulky stránek neznal - doplníme prázdné, ať indexed_titles
	# sedí délkou na indexed_files. Skutečné titulky se doplní při dalším
	# přeindexování.
	for i in range(indexed_files.size()):
		indexed_titles.append("")

	save_index()
	DirAccess.remove_absolute(INDEX_PATH_LEGACY_JSON)
	return true


# Kompletně smaže starý index (kdyby byl poškozený/zastaralý) i případný
# rozpracovaný (nedokončený) stav indexování, ať se dá začít úplně od nuly.
func clear_index() -> void:
	index_data.clear()
	indexed_files.clear()
	indexed_titles.clear()
	last_index_time = 0
	_sorted_words_dirty = true
	if FileAccess.file_exists(INDEX_PATH):
		DirAccess.remove_absolute(INDEX_PATH)
	if FileAccess.file_exists(INDEX_PATH_LEGACY_JSON):
		DirAccess.remove_absolute(INDEX_PATH_LEGACY_JSON)
	_clear_indexing_state()


# ---------------------------------------------------------------------------
# Indexace - rekurzivní průchod složkou
# ---------------------------------------------------------------------------

func index_folder_async(path: String, resume: bool = false) -> void:
	is_indexing = true
	indexing_progress = 0.0

	var files: Array = []
	var start_index := 0

	if resume:
		var state := _load_indexing_state()
		if state.size() > 0 and state.get("folder", "") == path:
			files = _load_filelist()
			start_index = int(state.get("current_index", 0))
			index_data = state.get("words", {})
			indexed_files = state.get("indexed_files", [])
			indexed_titles = state.get("indexed_titles", [])
			# Kdyby stav pocházel ještě z verze appky bez titulků, doplníme
			# chybějící prázdné položky, ať index odpovídá indexed_files.
			while indexed_titles.size() < indexed_files.size():
				indexed_titles.append("")
			indexing_status_text = "Navazuji na předchozí indexování (%d/%d)..." % [start_index, files.size()]
			indexing_progress_changed.emit(float(start_index) / float(max(files.size(), 1)), indexing_status_text)
			if files.is_empty():
				resume = false  # seznam souborů se ztratil/poškodil, radši začneme znovu
		else:
			resume = false  # uložený stav neodpovídá požadované složce, začneme znovu

	if not resume:
		index_data.clear()
		indexed_files.clear()
		indexed_titles.clear()
		_scan_counter = 0
		indexing_status_text = "Prohledávám složky..."
		indexing_progress_changed.emit(0.0, indexing_status_text)
		await _collect_files_async(path, files)
		# Seznam souborů se od teď do konce běhu neměnní - uložíme ho JEDNOU
		# zvlášť, ať se nemusí zbytečně znovu a znovu serializovat při
		# každém průběžném checkpointu (viz níže).
		_save_filelist(files)

	_sorted_words_dirty = true

	var total := files.size()
	if total == 0:
		is_indexing = false
		_clear_indexing_state()
		indexing_status_text = "Ve složce nebyly nalezeny žádné podporované soubory."
		indexing_finished.emit()
		return

	var last_checkpoint_ms := Time.get_ticks_msec()

	for i in range(start_index, total):
		var file_path: String = files[i]
		var file_id := indexed_files.size()  # index do indexed_files - viz komentář u _index_file
		var title := _index_file(file_path, file_id)
		indexed_files.append(file_path)
		indexed_titles.append(title)

		# Progress a "pusť enginu na frame" děláme jen po dávkách, ne po
		# každém souboru - čekání na frame po každém jednom souboru tvrdě
		# omezovalo rychlost na max. FPS souborů/s (typicky 60/s), i kdyby
		# to appka jinak zvládla mnohem rychleji.
		if (i + 1) % INDEX_YIELD_EVERY == 0 or i == total - 1:
			indexing_progress = float(i + 1) / float(total)
			indexing_status_text = "Indexuji (%d/%d): %s" % [i + 1, total, file_path.get_file()]
			indexing_progress_changed.emit(indexing_progress, indexing_status_text)

		# Průběžné ukládání rozpracovaného stavu - kdyby appka spadla nebo
		# ji systém uprostřed zabil, půjde po znovuotevření navázat místo
		# toho, aby se muselo začínat od nuly. Ukládáme podle UPLYNULÉHO ČASU
		# (ne podle pevného počtu souborů) - u malých/přerušených běhů se tak
		# garantuje aspoň jeden checkpoint, i kdyby appka spadla po pár
		# sekundách. Seznam souborů (files) se sem už neukládá, jen to, co
		# se mezi checkpointy skutečně mění.
		if Time.get_ticks_msec() - last_checkpoint_ms >= CHECKPOINT_INTERVAL_MS:
			_save_indexing_state(path, i + 1)
			last_checkpoint_ms = Time.get_ticks_msec()

		if (i + 1) % INDEX_YIELD_EVERY == 0:
			await Engine.get_main_loop().process_frame

	last_index_time = Time.get_unix_time_from_system()
	_sorted_words_dirty = true
	save_index()
	_clear_indexing_state()
	is_indexing = false
	indexing_finished.emit()


const CHECKPOINT_INTERVAL_MS := 10000  # jak často (v ms) se ukládá rozpracovaný stav
# Prodlouženo z 3s na 10s: každý checkpoint pořád znamená serializaci CELÉHO
# dosavadního indexu (jinak by se nedalo navázat), takže i po zmenšení
# datové struktury (PackedInt32Array) je zbytečné to dělat moc často -
# stačí garantovat, že se při pádu neztratí víc než pár desítek sekund práce.
const INDEX_YIELD_EVERY := 8    # jak často appka "pustí" frame enginu (UI responsivita)


# ---------------------------------------------------------------------------
# Atomický zápis na disk
# ---------------------------------------------------------------------------
# Zápis rovnou do cílového souboru je nebezpečný - pokud appku systém zabije
# (nebo spadne) přesně UPROSTŘED zápisu (u velkých JSON souborů, jako je
# rozpracovaný stav indexování u tisíců souborů, to není zanedbatelná doba),
# vznikne napůl zapsaný, poškozený soubor. Při dalším čtení se nepovede
# rozparsovat a appka o něm tak potichu "neví" - i když tam reálně nějaký
# postup byl.
#
# Řešení: napřed zapsat do dočasného souboru (*.tmp), a teprve po úspěšném
# zápisu ho přejmenovat na cílový název. Přejmenování je (na běžných
# souborových systémech) prakticky okamžité, takže riziko zásahu přesně v tu
# nepatrnou chvíli je zanedbatelné - buď existuje starý kompletní soubor,
# nebo už nový kompletní soubor, nikdy nic mezi tím.
func _write_json_atomic(path: String, data) -> bool:
	var tmp_path := path + ".tmp"
	var f := FileAccess.open(tmp_path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(data))
	f.close()

	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	var err := DirAccess.rename_absolute(tmp_path, path)
	return err == OK


# Binární + gzip komprimovaná varianta téhož atomického zápisu - používá se
# pro index, rozpracovaný stav a filelist, protože ty bývají u rozsáhlých
# knihoven řádově větší než nastavení, kde JSON stačí. store_var ukládá
# hodnoty (včetně int klíčů ve slovnících) přímo binárně, ne jako text, a
# gzip navrch stlačí opakující se vzory ve struktuře.
func _write_var_compressed(path: String, data) -> bool:
	var tmp_path := path + ".tmp"
	var f := FileAccess.open_compressed(tmp_path, FileAccess.WRITE, FileAccess.COMPRESSION_GZIP)
	if f == null:
		return false
	f.store_var(data, false)
	f.close()

	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	var err := DirAccess.rename_absolute(tmp_path, path)
	return err == OK


func _read_var_compressed(path: String):
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open_compressed(path, FileAccess.READ, FileAccess.COMPRESSION_GZIP)
	if f == null:
		return null
	var data = f.get_var(false)
	f.close()
	return data


func _save_indexing_state(path: String, current_index: int) -> void:
	_write_var_compressed(INDEXING_STATE_PATH, {
		"version": INDEX_FORMAT_VERSION,
		"folder": path,
		"current_index": current_index,
		"words": index_data,
		"indexed_files": indexed_files,
		"indexed_titles": indexed_titles,
	})

func _load_indexing_state() -> Dictionary:
	var parsed = _read_var_compressed(INDEXING_STATE_PATH)
	if typeof(parsed) == TYPE_DICTIONARY and int(parsed.get("version", 1)) >= INDEX_FORMAT_VERSION:
		return parsed
	return {}

func _clear_indexing_state() -> void:
	if FileAccess.file_exists(INDEXING_STATE_PATH):
		DirAccess.remove_absolute(INDEXING_STATE_PATH)
	if FileAccess.file_exists(INDEXING_FILELIST_PATH):
		DirAccess.remove_absolute(INDEXING_FILELIST_PATH)


# Seznam souborů k zaindexování se od konce prohledávání do konce indexace
# neměnní - uložíme ho jen JEDNOU (ne při každém checkpointu), ať se
# zbytečně neserializuje pořád dokola.
func _save_filelist(files: Array) -> void:
	_write_var_compressed(INDEXING_FILELIST_PATH, {"files": files})

func _load_filelist() -> Array:
	var parsed = _read_var_compressed(INDEXING_FILELIST_PATH)
	if typeof(parsed) == TYPE_DICTIONARY:
		return parsed.get("files", [])
	return []

# Zjistí, jestli existuje rozpracované (nedokončené) indexování a vrátí
# o něm info pro zobrazení v UI ({} pokud žádné není).
func get_resumable_indexing_info() -> Dictionary:
	var state := _load_indexing_state()
	if state.size() == 0:
		return {}
	var total := _load_filelist().size()
	return {
		"folder": state.get("folder", ""),
		"current": int(state.get("current_index", 0)),
		"total": total,
	}


var _scan_counter: int = 0

# Kolik položek (souborů + podsložek) zkontrolovat mezi jednotlivými "nádechy"
# (návraty enginu). Menší číslo = plynulejší UI, ale pomalejší celkové
# prohledání; větší číslo = rychlejší, ale méně plynulé updaty. 60 je rozumný
# kompromis - UI se aktualizuje typicky několikrát za sekundu i na obřím stromu.
const SCAN_YIELD_EVERY := 60

func _collect_files_async(path: String, out_files: Array) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name != "." and name != "..":
			var full_path := path.path_join(name)
			if dir.current_is_dir():
				if not (name in SKIP_DIRECTORIES):
					await _collect_files_async(full_path, out_files)
			else:
				var ext := name.get_extension().to_lower()
				if (ext in ALLOWED_EXTENSIONS) and _is_probably_text(full_path):
					out_files.append(full_path)

			_scan_counter += 1
			if _scan_counter % SCAN_YIELD_EVERY == 0:
				indexing_status_text = "Prohledávám složky... (nalezeno %d souborů, zkontrolováno %d položek)" % [out_files.size(), _scan_counter]
				# Progress bar tady nemá reálné 0-100 %, protože celkový počet
				# ještě neznáme - jen "pulzuje" v cyklu 0-100, ať je vidět, že
				# to opravdu pracuje a nezaseklo se to.
				indexing_progress_changed.emit(float(_scan_counter % 100) / 100.0, indexing_status_text)
				await Engine.get_main_loop().process_frame
		name = dir.get_next()
	dir.list_dir_end()


func _is_probably_text(file_path: String) -> bool:
	var f := FileAccess.open(file_path, FileAccess.READ)
	if f == null:
		return false
	var length := f.get_length()
	if length < MIN_FILE_SIZE_BYTES:
		f.close()
		return false
	if length > MAX_FILE_SIZE_BYTES:
		f.close()
		return false
	var sample_size: int = min(length, 4096)
	var bytes := f.get_buffer(sample_size)
	f.close()
	var suspicious := 0
	for b in bytes:
		if b == 0:
			return false  # NULL byte = téměř jistě binární soubor
		if b < 9 or (b > 13 and b < 32):
			suspicious += 1
	return float(suspicious) / float(bytes.size()) < 0.05


# Hodnota v index_data[slovo] je PackedInt32Array dvojic [file_id, pocet,
# file_id, pocet, ...] - viz komentář u proměnné index_data výše. file_id je
# pozice v poli indexed_files, zpátky na cestu se překládá až při zobrazení
# výsledků hledání. Vrací titulek stránky (viz _extract_title), který si
# volající uloží do indexed_titles na stejnou pozici jako file_id.
func _index_file(file_path: String, file_id: int) -> String:
	var f := FileAccess.open(file_path, FileAccess.READ)
	if f == null:
		return ""
	var raw := f.get_as_text()
	f.close()

	var title := _extract_title(raw)

	var clean := strip_markup(raw)
	var words := _tokenize(clean)

	var counted_in_file: Dictionary = {}
	for w in words:
		counted_in_file[w] = counted_in_file.get(w, 0) + 1

	for w in counted_in_file.keys():
		var pairs: PackedInt32Array = index_data.get(w, PackedInt32Array())
		pairs.append(file_id)
		pairs.append(counted_in_file[w])
		index_data[w] = pairs

	return title


func _tokenize(text: String) -> Array:
	var lower := text.to_lower()
	var found := _re_word.search_all(lower)
	var words: Array = []
	for m in found:
		var w: String = m.get_string()
		w = strip_diacritics(w)
		if w.length() >= 3 and not STOPWORDS.has(w):
			words.append(w)
	return words


# ---------------------------------------------------------------------------
# Čištění HTML/JS/CSS - vrací čistý text
# ---------------------------------------------------------------------------

# Vytáhne obsah <title>...</title> z HTML, očistí ho od případných
# vnořených značek/entit a zkrátí na rozumnou délku pro zobrazení ve
# výsledcích hledání. Vrací "" když soubor title tag nemá (typicky prostý
# text bez HTML).
func _extract_title(raw: String) -> String:
	var m := _re_title.search(raw)
	if m == null:
		return ""
	var title: String = m.get_string(1)
	title = _re_tag.sub(title, " ", true)
	title = title.replace("&nbsp;", " ")
	title = title.replace("&amp;", "&")
	title = title.replace("&lt;", "<")
	title = title.replace("&gt;", ">")
	title = title.replace("&quot;", "\"")
	title = title.replace("&#39;", "'")
	title = _re_ws.sub(title, " ", true).strip_edges()
	if title.length() > 200:
		title = title.substr(0, 200) + "…"
	return title


func strip_markup(text: String) -> String:
	var result := text

	# 1) Kompletně odstranit obsah <script>...</script> a <style>...</style>
	result = _strip_block(result, "<script", "</script>")
	result = _strip_block(result, "<style", "</style>")

	# 2) Odstranit HTML komentáře <!-- ... -->
	result = _re_comment.sub(result, "", true)

	# 3) Odstranit zbylé HTML značky <...>
	result = _re_tag.sub(result, " ", true)

	# 4) Dekódovat běžné HTML entity
	result = result.replace("&nbsp;", " ")
	result = result.replace("&amp;", "&")
	result = result.replace("&lt;", "<")
	result = result.replace("&gt;", ">")
	result = result.replace("&quot;", "\"")
	result = result.replace("&#39;", "'")

	# 5) Sloučit nadbytečné bílé znaky
	result = _re_ws.sub(result, " ", true)
	result = _re_nl.sub(result, "\n\n", true)

	return result.strip_edges()


func _strip_block(text: String, start_tag: String, end_tag: String) -> String:
	var result := text
	var lower := text.to_lower()
	while true:
		var start_idx := lower.find(start_tag)
		if start_idx == -1:
			break
		var tag_close := lower.find(">", start_idx)
		if tag_close == -1:
			break
		var end_idx := lower.find(end_tag, tag_close)
		if end_idx == -1:
			# chybějící koncová značka - useknout zbytek souboru
			result = result.substr(0, start_idx)
			lower = lower.substr(0, start_idx)
			break
		var end_full := end_idx + end_tag.length()
		result = result.substr(0, start_idx) + result.substr(end_full)
		lower = lower.substr(0, start_idx) + lower.substr(end_full)
	return result


# ---------------------------------------------------------------------------
# Vyhledávání
# ---------------------------------------------------------------------------

# Seřazené pole všech slov v indexu - umožňuje binární vyhledávání (O(log n))
# místo lineárního průchodu přes všechna slova (O(n)) při každém hledání.
# Přebuduje se líně, jen když se index mezitím opravdu změnil.
var _sorted_words: Array = []
var _sorted_words_dirty: bool = true

func _ensure_sorted_words() -> void:
	if not _sorted_words_dirty:
		return
	_sorted_words = index_data.keys()
	_sorted_words.sort()
	_sorted_words_dirty = false


# Vrátí všechna slova z indexu, která ZAČÍNAJÍ na "term" - přes binární
# vyhledávání v seřazeném poli (rychlé i na desetitisících slov).
#
# Pozn.: tohle najde jen shody OD ZAČÁTKU slova (prefix), ne "kdekoli uvnitř"
# jako předtím (např. "dex" najde "index" jen v novém způsobu, kdyby to bylo
# "kdekoli uvnitř"; v prefixovém způsobu "dex" nenajde "index", ale "inde"
# ano). Binární vyhledávání funguje jen díky tomu, že seřazená slova se
# stejným začátkem leží v poli hned vedle sebe - "kdekoli uvnitř" by binární
# vyhledávání využít nešlo (vyžadovalo by mnohem složitější strukturu jako
# suffix trie), takže by hledání zůstalo pomalé O(n). V praxi prefixové
# hledání pokryje naprostou většinu běžného použití (psaní od začátku slova).
func _matching_words(term: String) -> Array:
	var n := _sorted_words.size()
	if n == 0:
		return []

	# bsearch najde první index, kde by "term" šlo vložit a pole zůstalo
	# seřazené - tedy první slovo >= term.
	var start := _sorted_words.bsearch(term, true)
	var result: Array = []
	var i := start
	while i < n and (_sorted_words[i] as String).begins_with(term):
		result.append(_sorted_words[i])
		i += 1
	return result


func search(query: String) -> Array:
	query = strip_diacritics(query.strip_edges().to_lower())
	if query.is_empty():
		return []

	var terms := query.split(" ", false)
	if terms.is_empty():
		return []

	_ensure_sorted_words()

	# Pro každé zadané slovo zjistíme, které soubory (podle ID, viz
	# _index_file) ho obsahují a s jakým součtem výskytů, pak uděláme
	# průnik - musí sedět VŠECHNA zadaná slova.
	var matches_per_term: Array = []  # Array[Dictionary: file_id (int) -> count]

	for term in terms:
		var term_matches: Dictionary = {}
		for word in _matching_words(term):
			var pairs: PackedInt32Array = index_data[word]
			var n := pairs.size()
			var i := 0
			while i < n:
				var fid: int = pairs[i]
				var cnt: int = pairs[i + 1]
				term_matches[fid] = term_matches.get(fid, 0) + cnt
				i += 2
		matches_per_term.append(term_matches)

	var common_ids: Dictionary = matches_per_term[0].duplicate()
	for i in range(1, matches_per_term.size()):
		var next_matches: Dictionary = matches_per_term[i]
		for fid in common_ids.keys().duplicate():
			if not next_matches.has(fid):
				common_ids.erase(fid)

	var results: Array = []
	for fid in common_ids.keys():
		var file_id: int = int(fid)
		if file_id < 0 or file_id >= indexed_files.size():
			continue  # bezpečnostní pojistka proti nesedícím/poškozeným datům
		var total := 0
		for term_matches in matches_per_term:
			total += int(term_matches.get(fid, 0))
		var title: String = indexed_titles[file_id] if file_id < indexed_titles.size() else ""
		results.append({"path": indexed_files[file_id], "title": title, "count": total})

	results.sort_custom(func(a, b): return a["count"] > b["count"])
	return results


func get_reader_text(file_path: String) -> String:
	var f := FileAccess.open(file_path, FileAccess.READ)
	if f == null:
		return "Nelze otevřít soubor: " + file_path
	var raw := f.get_as_text()
	f.close()
	return strip_markup(raw)
