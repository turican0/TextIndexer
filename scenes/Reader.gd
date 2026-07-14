extends Control

const MIN_FONT_SIZE := 16
const MAX_FONT_SIZE := 64
const FONT_STEP := 4

@onready var text_label: TextEdit = $VBoxContainer/TextLabel
@onready var back_button: Button = $VBoxContainer/BottomBar/BackButton
@onready var minus_button: Button = $VBoxContainer/BottomBar/MinusButton
@onready var plus_button: Button = $VBoxContainer/BottomBar/PlusButton
@onready var title_label: Label = $VBoxContainer/TitleLabel


var _touch_scrolling := false
var _last_touch_pos := Vector2.ZERO


func _ready() -> void:
	back_button.pressed.connect(_on_back_pressed)
	minus_button.pressed.connect(_on_minus_pressed)
	plus_button.pressed.connect(_on_plus_pressed)

	var path: String = Indexer.current_reader_path
	var parent_dir := path.get_base_dir().get_file()
	title_label.text = "%s / %s" % [parent_dir, path.get_file()] if parent_dir != "" else path.get_file()
	text_label.text = Indexer.get_reader_text(path)

	# Barvy (a teď i pozadí) nastavujeme napevno v kódu (nezávisle na
	# globálním motivu), aby text nemohl nikdy skončit jako bílý na bílém
	# pozadí - a taky proto, že AppTheme.tres vůbec nedefinuje vzhled pro
	# TextEdit, takže dřív spadl na šedý výchozí motiv Godotu.
	title_label.add_theme_color_override("font_color", Color.BLACK)
	text_label.add_theme_color_override("font_color", Color.BLACK)
	# TextEdit má pro needitovatelný (editable = false) režim SAMOSTATNOU
	# barvu textu - font_readonly_color - která se použije MÍSTO font_color.
	# Proto byl text šedý/špatně čitelný i přes override výše.
	text_label.add_theme_color_override("font_readonly_color", Color.BLACK)

	var text_bg := StyleBoxFlat.new()
	text_bg.bg_color = Color.WHITE
	text_bg.content_margin_left = 4
	text_bg.content_margin_right = 4
	text_bg.content_margin_top = 4
	text_bg.content_margin_bottom = 4
	text_label.add_theme_stylebox_override("normal", text_bg)
	text_label.add_theme_stylebox_override("focus", text_bg)
	text_label.add_theme_stylebox_override("read_only", text_bg)

	title_label.add_theme_font_size_override("font_size", 44) # Větší titulek souboru

	if Indexer.reader_font_size < MIN_FONT_SIZE or Indexer.reader_font_size > MAX_FONT_SIZE:
		Indexer.reader_font_size = 36
	_apply_font_size()

	# TextEdit sám o sobě neumí scrollovat tažením prstu - tažení bere jako
	# výběr textu, který ale máme (schválně) vypnutý, takže se dřív nedělo
	# vůbec nic. Tady si tažení odchytáváme ručně a posouváme scroll_vertical.
	text_label.gui_input.connect(_on_text_gui_input)


func _on_text_gui_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			_touch_scrolling = true
			_last_touch_pos = event.position
		else:
			_touch_scrolling = false
	elif event is InputEventScreenDrag:
		if not _touch_scrolling:
			return
		var line_height := text_label.get_line_height()
		if line_height <= 0:
			line_height = 20
		var delta_y: float = _last_touch_pos.y - event.position.y
		text_label.scroll_vertical += delta_y / float(line_height)
		_last_touch_pos = event.position


func _apply_font_size() -> void:
	text_label.add_theme_font_size_override("font_size", Indexer.reader_font_size)


func _on_minus_pressed() -> void:
	Indexer.reader_font_size = max(MIN_FONT_SIZE, Indexer.reader_font_size - FONT_STEP)
	_apply_font_size()
	Indexer.save_settings()


func _on_plus_pressed() -> void:
	Indexer.reader_font_size = min(MAX_FONT_SIZE, Indexer.reader_font_size + FONT_STEP)
	_apply_font_size()
	Indexer.save_settings()


func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/Search.tscn")
