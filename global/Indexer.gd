extends Node

# ---------------------------------------------------------------------------
# Indexer - autoload singleton
# Zajišťuje: výběr/uložení cesty ke složce, rekurzivní indexaci textových
# souborů (s odstraněním HTML/JS), fulltextové hledání a čtení souboru
# v "reader" režimu (opět bez HTML/JS značek).
# ---------------------------------------------------------------------------

const SETTINGS_PATH := "user://settings.json"
const INDEX_PATH := "user://index.json"

# Přípony, které rovnou přeskočíme bez otevírání (typicky binární/mediální
# soubory) - čistě kvůli rychlosti, aby se nemusel číst obsah úplně
# každého souboru. Vše ostatní se posoudí podle obsahu (viz _is_probably_text).
const SKIP_EXTENSIONS := [
	"png", "jpg", "jpeg", "gif", "bmp", "webp", "ico", "tga", "exr", "hdr",
	"mp3", "wav", "ogg", "flac", "mp4", "avi", "mov", "mkv", "webm",
	"zip", "rar", "7z", "tar", "gz", "bz2",
	"exe", "dll", "so", "dylib", "bin", "dat", "db", "sqlite", "sqlite3",
	"ttf", "otf", "woff", "woff2", "pdf",
	"doc", "docx", "xls", "xlsx", "ppt", "pptx",
	"class", "jar", "pyc", "o", "obj", "a", "lib", "apk", "aab"
]

# Soubory větší než tohle se přeskočí (kvůli výkonu na mobilu).
const MAX_FILE_SIZE_BYTES := 4 * 1024 * 1024  # 4 MB

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

var selected_folder: String = ""
var selected_folder_raw: String = ""  # původní cesta/URI vrácená systémovým výběrem, před převodem
var reader_font_size: int = 36
var index_data: Dictionary = {}      # slovo -> { cesta_k_souboru: pocet_vyskytu }
var indexed_files: Array = []        # seznam všech zaindexovaných souborů
var current_reader_path: String = "" # cesta k souboru, který se má otevřít v Readeru

# Adresáře, které se při procházení úplně přeskočí (obvykle objemné a
# nezajímavé pro fulltextové hledání - cache, verzovací systém, závislosti...).
const SKIP_DIRECTORIES := [".git", ".import", ".godot", ".venv", "node_modules", "__pycache__", ".vs", ".vscode"]

var is_indexing: bool = false
var indexing_progress: float = 0.0
var indexing_status_text: String = ""

signal indexing_finished
signal indexing_progress_changed(progress: float, status: String)

func _ready() -> void:
	load_settings()
	load_index()


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
	var f := FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"folder": selected_folder, "reader_font_size": reader_font_size}))
		f.close()

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

func save_index() -> void:
	var f := FileAccess.open(INDEX_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"words": index_data, "files": indexed_files}))
		f.close()

func load_index() -> void:
	if not FileAccess.file_exists(INDEX_PATH):
		return
	var f := FileAccess.open(INDEX_PATH, FileAccess.READ)
	if f == null:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) == TYPE_DICTIONARY:
		if parsed.has("words"):
			index_data = parsed["words"]
			indexed_files = parsed.get("files", [])
		else:
			# zpětná kompatibilita se starším formátem indexu
			index_data = parsed
			indexed_files = []


# ---------------------------------------------------------------------------
# Indexace - rekurzivní průchod složkou
# ---------------------------------------------------------------------------

func index_folder_async(path: String) -> void:
	is_indexing = true
	indexing_progress = 0.0
	index_data.clear()
	indexed_files.clear()

	var files: Array = []
	_collect_files(path, files)

	var total := files.size()
	if total == 0:
		is_indexing = false
		indexing_status_text = "Ve složce nebyly nalezeny žádné podporované soubory."
		indexing_finished.emit()
		return

	for i in range(total):
		var file_path: String = files[i]
		_index_file(file_path)
		indexed_files.append(file_path)
		indexing_progress = float(i + 1) / float(total)
		indexing_status_text = "Indexuji (%d/%d): %s" % [i + 1, total, file_path.get_file()]
		indexing_progress_changed.emit(indexing_progress, indexing_status_text)
		# necháme frame proběhnout, aby UI nezamrzlo při velkém množství souborů
		await Engine.get_main_loop().process_frame

	save_index()
	is_indexing = false
	indexing_finished.emit()


func _collect_files(path: String, out_files: Array) -> void:
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
					_collect_files(full_path, out_files)
			else:
				var ext := name.get_extension().to_lower()
				if ext in SKIP_EXTENSIONS:
					name = dir.get_next()
					continue
				if _is_probably_text(full_path):
					out_files.append(full_path)
		name = dir.get_next()
	dir.list_dir_end()


func _is_probably_text(file_path: String) -> bool:
	var f := FileAccess.open(file_path, FileAccess.READ)
	if f == null:
		return false
	var length := f.get_length()
	if length == 0:
		f.close()
		return true
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


func _index_file(file_path: String) -> void:
	var f := FileAccess.open(file_path, FileAccess.READ)
	if f == null:
		return
	var raw := f.get_as_text()
	f.close()

	var clean := strip_markup(raw)
	var words := _tokenize(clean)

	var counted_in_file: Dictionary = {}
	for w in words:
		counted_in_file[w] = counted_in_file.get(w, 0) + 1

	for w in counted_in_file.keys():
		if not index_data.has(w):
			index_data[w] = {}
		index_data[w][file_path] = counted_in_file[w]


func _tokenize(text: String) -> Array:
	var lower := text.to_lower()
	var regex := RegEx.new()
	# \p{L} = libovolné písmeno (včetně diakritiky), \p{N} = číslice, _ kvůli identifikátorům v kódu
	regex.compile("[\\p{L}\\p{N}_]+")
	var found := regex.search_all(lower)
	var words: Array = []
	for m in found:
		var w: String = m.get_string()
		w = strip_diacritics(w)
		if w.length() >= 2:
			words.append(w)
	return words


# ---------------------------------------------------------------------------
# Čištění HTML/JS/CSS - vrací čistý text
# ---------------------------------------------------------------------------

func strip_markup(text: String) -> String:
	var result := text

	# 1) Kompletně odstranit obsah <script>...</script> a <style>...</style>
	result = _strip_block(result, "<script", "</script>")
	result = _strip_block(result, "<style", "</style>")

	# 2) Odstranit HTML komentáře <!-- ... -->
	var comment_re := RegEx.new()
	comment_re.compile("<!--[\\s\\S]*?-->")
	result = comment_re.sub(result, "", true)

	# 3) Odstranit zbylé HTML značky <...>
	var tag_re := RegEx.new()
	tag_re.compile("<[^>]*>")
	result = tag_re.sub(result, " ", true)

	# 4) Dekódovat běžné HTML entity
	result = result.replace("&nbsp;", " ")
	result = result.replace("&amp;", "&")
	result = result.replace("&lt;", "<")
	result = result.replace("&gt;", ">")
	result = result.replace("&quot;", "\"")
	result = result.replace("&#39;", "'")

	# 5) Sloučit nadbytečné bílé znaky
	var ws_re := RegEx.new()
	ws_re.compile("[ \\t]+")
	result = ws_re.sub(result, " ", true)

	var nl_re := RegEx.new()
	nl_re.compile("\\n{3,}")
	result = nl_re.sub(result, "\n\n", true)

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

func search(query: String) -> Array:
	query = strip_diacritics(query.strip_edges().to_lower())
	if query.is_empty():
		return []

	var terms := query.split(" ", false)
	if terms.is_empty():
		return []

	# Pro každé zadané slovo zjistíme, které soubory ho obsahují (a s jakým
	# součtem výskytů), pak uděláme průnik - musí sedět VŠECHNA zadaná slova.
	var matches_per_term: Array = []  # Array[Dictionary: file_path -> count]

	for term in terms:
		var term_matches: Dictionary = {}
		for word in index_data.keys():
			if word.find(term) != -1:
				var files_dict: Dictionary = index_data[word]
				for fp in files_dict.keys():
					term_matches[fp] = term_matches.get(fp, 0) + int(files_dict[fp])
		matches_per_term.append(term_matches)

	var common_files: Dictionary = matches_per_term[0].duplicate()
	for i in range(1, matches_per_term.size()):
		var next_matches: Dictionary = matches_per_term[i]
		for fp in common_files.keys().duplicate():
			if not next_matches.has(fp):
				common_files.erase(fp)

	var results: Array = []
	for fp in common_files.keys():
		var total := 0
		for term_matches in matches_per_term:
			total += int(term_matches.get(fp, 0))
		results.append({"path": fp, "count": total})

	results.sort_custom(func(a, b): return a["count"] > b["count"])
	return results


func get_reader_text(file_path: String) -> String:
	var f := FileAccess.open(file_path, FileAccess.READ)
	if f == null:
		return "Nelze otevřít soubor: " + file_path
	var raw := f.get_as_text()
	f.close()
	return strip_markup(raw)
