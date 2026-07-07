extends Control

@onready var folder_label: Label = $VBoxContainer/FolderLabel
@onready var pick_button: Button = $VBoxContainer/PickFolderButton
@onready var index_button: Button = $VBoxContainer/IndexButton
@onready var progress_bar: ProgressBar = $VBoxContainer/ProgressBar
@onready var progress_label: Label = $VBoxContainer/ProgressLabel
@onready var back_button: Button = $VBoxContainer/BackButton
@onready var permission_button: Button = $VBoxContainer/PermissionButton


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
	$VBoxContainer/TitleLabel.add_theme_color_override("font_color", Color.BLACK)
	folder_label.add_theme_color_override("font_color", Color.BLACK)
	progress_label.add_theme_color_override("font_color", Color.BLACK)

	$VBoxContainer/TitleLabel.add_theme_font_size_override("font_size", 38) # Větší hlavní titulek
	folder_label.add_theme_font_size_override("font_size", 26)              # Cesta k adresáři
	progress_label.add_theme_font_size_override("font_size", 24)            # Stav indexace


func _refresh_folder_label() -> void:
	var f := Indexer.selected_folder
	folder_label.text = "Vybraná složka: %s" % (f if f != "" else "(žádná)")


func _on_permission_pressed() -> void:
	Indexer.request_storage_permission()


func _on_pick_folder() -> void:
	var browser := preload("res://scenes/FolderBrowser.tscn").instantiate()
	add_child(browser)
	browser.folder_selected.connect(_on_folder_selected)


func _on_folder_selected(path: String) -> void:
	Indexer.selected_folder = path
	Indexer.save_settings()
	_refresh_folder_label()


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


func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/Search.tscn")
