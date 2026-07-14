extends Control

@onready var search_edit: LineEdit = $VBoxContainer/SearchEdit
@onready var results_container: VBoxContainer = $VBoxContainer/ScrollContainer/ResultsContainer
@onready var settings_button: Button = $VBoxContainer/TopBar/SettingsButton
@onready var status_label: Label = $VBoxContainer/StatusLabel
@onready var search_debounce: Timer = $SearchDebounce


func _ready() -> void:
	search_edit.text_changed.connect(_on_text_changed)
	search_debounce.timeout.connect(_on_debounce_timeout)
	settings_button.pressed.connect(_on_settings_pressed)
	_update_status()
	_run_search(search_edit.text)

	# Barvy nastavujeme napevno v kódu (nezávisle na globálním motivu),
	# aby text nemohl nikdy skončit jako bílý na bílém pozadí.
	$VBoxContainer/TopBar/TitleLabel.add_theme_color_override("font_color", Color.BLACK)
	status_label.add_theme_color_override("font_color", Color(0.25, 0.25, 0.25, 1))
	search_edit.add_theme_color_override("font_color", Color.BLACK)
	search_edit.add_theme_color_override("font_placeholder_color", Color(0.45, 0.45, 0.45, 1))

	$VBoxContainer/TopBar/TitleLabel.add_theme_font_size_override("font_size", 52) # Větší titulek
	status_label.add_theme_font_size_override("font_size", 28)                     # Menší stavový řádek


func _on_text_changed(_new_text: String) -> void:
	# Počkej, až uživatel na chvíli přestane psát, než spustíme
	# (relativně dražší) podřetězcové hledání přes celý index.
	search_debounce.start()


func _on_debounce_timeout() -> void:
	_run_search(search_edit.text)


func _update_status() -> void:
	var word_count := Indexer.index_data.size()
	var file_count := Indexer.indexed_files.size()

	var resumable := Indexer.get_resumable_indexing_info()
	var resume_note := ""
	if resumable.size() > 0:
		resume_note = "\n⚠ Nedokončené indexování (%d/%d souborů) - dokonči ho v Nastavení." % [resumable["current"], resumable["total"]]

	if word_count == 0:
		status_label.text = "Index je prázdný. Přejdi do Nastavení a naindexuj složku." + resume_note
	else:
		var folder := Indexer.selected_folder
		var when := "nikdy"
		if Indexer.last_index_time > 0:
			when = Time.get_datetime_string_from_unix_time(Indexer.last_index_time, true).replace("T", " ")
		status_label.text = "Souborů: %d   |   Unikátních slov: %d   |   Složka: %s\nNaposledy zaindexováno: %s%s" % [file_count, word_count, folder, when, resume_note]


func _on_settings_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/Settings.tscn")


func _run_search(new_text: String) -> void:
	for child in results_container.get_children():
		child.queue_free()

	var trimmed := new_text.strip_edges()
	if trimmed.is_empty():
		return

	if trimmed.length() < 3:
		var lbl := Label.new()
		lbl.text = "Napiš aspoň 3 znaky - kratší slova se neindexují."
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
		lbl.add_theme_color_override("font_color", Color.BLACK)
		results_container.add_child(lbl)
		return

	var results := Indexer.search(new_text)

	if results.is_empty():
		var lbl := Label.new()
		if Indexer.index_data.is_empty():
			lbl.text = "Nic nenalezeno - index je prázdný (žádná složka ještě nebyla úspěšně zaindexována)."
		else:
			lbl.text = "Nic nenalezeno. (Index obsahuje %d souborů / %d slov, ale hledaný výraz v nich není.)" % [Indexer.indexed_files.size(), Indexer.index_data.size()]
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
		lbl.add_theme_color_override("font_color", Color.BLACK)
		results_container.add_child(lbl)
		return

	for r in results:
		var btn := Button.new()
		var file_path: String = r["path"]
		var title: String = String(r.get("title", "")).strip_edges()
		var parent_dir := file_path.get_base_dir().get_file()
		var display_name := "%s / %s" % [parent_dir, file_path.get_file()] if parent_dir != "" else file_path.get_file()
		# Titulek stránky (<title>...</title>) pomáhá poznat, o jaký soubor
		# jde, líp než jen technický název souboru - pokud ho soubor nemá
		# (např. prostý .txt), zobrazí se aspoň název souboru samotný.
		if title.is_empty():
			title = file_path.get_file()
		btn.text = "%s\n%s   (%d×)" % [title, display_name, r["count"]]
		btn.tooltip_text = file_path
		btn.custom_minimum_size.y = 170
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.add_theme_font_size_override("font_size", 34)
		btn.add_theme_color_override("font_color", Color.BLACK)
		btn.add_theme_color_override("font_hover_color", Color.BLACK)
		btn.add_theme_color_override("font_pressed_color", Color.BLACK)
		# Bez tohohle tlačítko "spolklo" dotykové gesto ještě předtím, než se
		# dostalo k obalujícímu ScrollContaineru - PASS zajistí, že se přes
		# tlačítko dá pořád normálně kliknout (tap), ale zároveň gesto
		# doputuje i výš, takže ScrollContainer může scrollovat i tažením
		# prstem přes seznam tlačítek.
		btn.mouse_filter = Control.MOUSE_FILTER_PASS
		btn.pressed.connect(_on_result_pressed.bind(file_path))
		results_container.add_child(btn)


func _on_result_pressed(path: String) -> void:
	Indexer.current_reader_path = path
	get_tree().change_scene_to_file("res://scenes/Reader.tscn")
