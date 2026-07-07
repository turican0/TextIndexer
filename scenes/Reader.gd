extends Control

const MIN_FONT_SIZE := 16
const MAX_FONT_SIZE := 64
const FONT_STEP := 4

@onready var text_label: RichTextLabel = $VBoxContainer/ScrollContainer/TextLabel
@onready var back_button: Button = $VBoxContainer/BottomBar/BackButton
@onready var minus_button: Button = $VBoxContainer/BottomBar/MinusButton
@onready var plus_button: Button = $VBoxContainer/BottomBar/PlusButton
@onready var title_label: Label = $VBoxContainer/TitleLabel


func _ready() -> void:
	back_button.pressed.connect(_on_back_pressed)
	minus_button.pressed.connect(_on_minus_pressed)
	plus_button.pressed.connect(_on_plus_pressed)

	var path: String = Indexer.current_reader_path
	title_label.text = path.get_file()
	text_label.text = Indexer.get_reader_text(path)

	# Barvy nastavujeme napevno v kódu (nezávisle na globálním motivu),
	# aby text nemohl nikdy skončit jako bílý na bílém pozadí.
	title_label.add_theme_color_override("font_color", Color.BLACK)
	text_label.add_theme_color_override("default_color", Color.BLACK)
	text_label.add_theme_color_override("font_selected_color", Color.WHITE)
	text_label.add_theme_color_override("selection_color", Color(0.2, 0.4, 0.9, 0.6))

	title_label.add_theme_font_size_override("font_size", 34) # Větší titulek souboru

	if Indexer.reader_font_size < MIN_FONT_SIZE or Indexer.reader_font_size > MAX_FONT_SIZE:
		Indexer.reader_font_size = 30
	_apply_font_size()


func _apply_font_size() -> void:
	text_label.add_theme_font_size_override("normal_font_size", Indexer.reader_font_size)
	text_label.add_theme_font_size_override("bold_font_size", Indexer.reader_font_size)
	text_label.add_theme_font_size_override("italics_font_size", Indexer.reader_font_size)


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
