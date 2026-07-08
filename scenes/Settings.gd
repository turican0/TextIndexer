extends Control

@onready var folder_label: Label = $ScrollContainer/VBoxContainer/FolderLabel
@onready var diagnostics_label: Label = $ScrollContainer/VBoxContainer/DiagnosticsLabel
@onready var pick_button: Button = $ScrollContainer/VBoxContainer/PickFolderButton
@onready var index_button: Button = $ScrollContainer/VBoxContainer/IndexButton
@onready var progress_bar: ProgressBar = $ScrollContainer/VBoxContainer/ProgressBar
@onready var progress_label: Label = $ScrollContainer/VBoxContainer/ProgressLabel
@onready var back_button: Button = $ScrollContainer/VBoxContainer/BackButton
@onready var permission_button: Button = $ScrollContainer/VBoxContainer/PermissionButton
@onready var permission_info_dialog: AcceptDialog = $PermissionInfoDialog


func _ready() -> void:
	pick_button.pressed.connect(_on_pick_folder)
	index_button.pressed.connect(_on_index_pressed)
	back_button.pressed.connect(_on_back_pressed)
	permission_button.pressed.connect(_on_permission_pressed)
	Indexer.indexing_progress_changed.connect(_on_progress)
	Indexer.indexing_finished.connect(_on_finished)

	_refresh_folder_label()
	progress_bar.visible = false
	progress_label.visible = false

	# Barvy nastavujeme napevno v kódu (nezávisle na globálním motivu),
	# aby text nemohl nikdy skončit jako bílý na bílém pozadí.
	$ScrollContainer/VBoxContainer/TitleLabel.add_theme_color_override("font_color", Color.BLACK)
	folder_label.add_theme_color_override("font_color", Color.BLACK)
	diagnostics_label.add_theme_color_override("font_color", Color(0.35, 0.35, 0.35, 1))
	progress_label.add_theme_color_override("font_color", Color.BLACK)

	# Pokud už nějaká složka byla vybraná dřív, rovnou zkontrolujeme,
	# jestli je reálně čitelná.
	if Indexer.selected_folder != "":
		_run_diagnostics(Indexer.selected_folder)


func _refresh_folder_label() -> void:
	var f := Indexer.selected_folder
	folder_label.text = "Vybraná složka: %s" % (f if f != "" else "(žádná)")


func _run_diagnostics(path: String) -> void:
	diagnostics_label.text = Indexer.diagnose_path(path)


func _on_permission_pressed() -> void:
	if OS.get_name() != "Android":
		return

	# Nejdřív zkusíme klasický systémový dialog (na starších verzích Androidu
	# - do API 29 - to ještě funguje pro READ/WRITE_EXTERNAL_STORAGE).
	Indexer.request_storage_permission()

	# Na Androidu 11+ tenhle dialog ale běžně nic nezobrazí, protože plný
	# přístup ("Přístup ke všem souborům") jde zapnout jen ručně v Nastavení -
	# Godot bez vlastního nativního pluginu neumí tu konkrétní obrazovku
	# otevřít programově, proto vždy zobrazíme přesný manuální návod.
	permission_info_dialog.dialog_text = "Pro spolehlivé čtení souborů (hlavně mimo aplikaci, např. Download) je potřeba zapnout plný přístup k úložišti ručně:\n\nNastavení telefonu → Aplikace → TextIndexer → Oprávnění → Soubory a média → Povolit správu všech souborů (\"All files access\").\n\nBez toho může výběr složky projít, ale čtení souborů skončí s 0 výsledky."
	permission_info_dialog.popup_centered()


func _on_pick_folder() -> void:
	var browser := preload("res://scenes/FolderBrowser.tscn").instantiate()
	add_child(browser)
	browser.folder_selected.connect(_on_folder_selected)


func _on_folder_selected(path: String) -> void:
	Indexer.selected_folder = path
	Indexer.save_settings()
	_refresh_folder_label()
	_run_diagnostics(path)


func _on_index_pressed() -> void:
	if Indexer.selected_folder.is_empty():
		progress_label.visible = true
		progress_label.text = "Nejdřív vyber složku."
		return

	progress_bar.visible = true
	progress_label.visible = true
	progress_bar.value = 0
	index_button.disabled = true
	pick_button.disabled = true

	Indexer.index_folder_async(Indexer.selected_folder)


func _on_progress(progress: float, status: String) -> void:
	progress_bar.value = progress * 100.0
	progress_label.text = status


func _on_finished() -> void:
	progress_label.text = "Indexování dokončeno. Souborů: %d, unikátních slov: %d" % [Indexer.indexed_files.size(), Indexer.index_data.size()]
	index_button.disabled = false
	pick_button.disabled = false

	if Indexer.indexed_files.size() == 0:
		_run_diagnostics(Indexer.selected_folder)
		diagnostics_label.text = "Diagnostika 0 souborů:\n" + diagnostics_label.text


func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/Search.tscn")
