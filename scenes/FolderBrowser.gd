extends Control

# Jednoduchý vlastní prohlížeč adresářů. Godot nemá vestavěný nativní
# Android SAF "vyber složku" dialog bez pluginu, takže tady procházíme
# souborový systém ručně pomocí DirAccess. Každá složka je velké tlačítko
# přes celou šířku, aby se na něj dalo pohodlně klepnout prstem.

signal folder_selected(path: String)

@onready var path_label: Label = $Panel/VBoxContainer/PathLabel
@onready var list_container: VBoxContainer = $Panel/VBoxContainer/ScrollContainer/ListContainer
@onready var up_button: Button = $Panel/VBoxContainer/HBoxContainer/UpButton
@onready var select_button: Button = $Panel/VBoxContainer/HBoxContainer/SelectButton
@onready var cancel_button: Button = $Panel/VBoxContainer/HBoxContainer/CancelButton
@onready var native_folder_dialog: FileDialog = $NativeFolderDialog

var current_path: String = ""


func _ready() -> void:
	# Na Androidu (11+) nemá vlastní procházení přes DirAccess přístup ke
	# sdíleným složkám jako Download - jde o tzv. scoped storage. Řešíme to
	# systémovým (nativním) výběrem složky, který používá Android Storage
	# Access Framework a funguje bez zvláštního oprávnění MANAGE_EXTERNAL_STORAGE.
	if OS.get_name() == "Android":
		native_folder_dialog.dir_selected.connect(_on_native_dir_selected)
		native_folder_dialog.canceled.connect(_on_cancel)
		$Panel.visible = false
		native_folder_dialog.popup_centered()
		return

	if Indexer.selected_folder != "" and DirAccess.dir_exists_absolute(Indexer.selected_folder):
		current_path = Indexer.selected_folder
	else:
		current_path = OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)

	up_button.pressed.connect(_on_up)
	select_button.pressed.connect(_on_select)
	cancel_button.pressed.connect(_on_cancel)

	_refresh()


func _on_native_dir_selected(path: String) -> void:
	folder_selected.emit(path)
	queue_free()


func _refresh() -> void:
	path_label.text = current_path

	for child in list_container.get_children():
		child.queue_free()

	var dir := DirAccess.open(current_path)
	if dir == null:
		path_label.text = current_path + "\n(nelze otevřít - chybí oprávnění?)"
		return

	dir.list_dir_begin()
	var name := dir.get_next()
	var dirs: Array = []
	while name != "":
		if name != "." and name != "..":
			if dir.current_is_dir():
				dirs.append(name)
		name = dir.get_next()
	dir.list_dir_end()

	dirs.sort()

	if dirs.is_empty():
		var lbl := Label.new()
		lbl.text = "(žádné podsložky)"
		lbl.add_theme_font_size_override("font_size", 22)
		list_container.add_child(lbl)
		return

	for d in dirs:
		var btn := Button.new()
		btn.text = "📁  " + d
		btn.custom_minimum_size.y = 120
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.add_theme_font_size_override("font_size", 28)
		btn.pressed.connect(_on_folder_row_pressed.bind(d))
		list_container.add_child(btn)


func _on_folder_row_pressed(folder_name: String) -> void:
	current_path = current_path.path_join(folder_name)
	_refresh()


func _on_up() -> void:
	var parent := current_path.get_base_dir()
	if parent != "" and parent != current_path:
		current_path = parent
		_refresh()


func _on_select() -> void:
	folder_selected.emit(current_path)
	queue_free()


func _on_cancel() -> void:
	queue_free()
