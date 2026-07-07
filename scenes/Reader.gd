extends Control

@onready var text_label: RichTextLabel = $VBoxContainer/ScrollContainer/TextLabel
@onready var back_button: Button = $VBoxContainer/BackButton
@onready var title_label: Label = $VBoxContainer/TitleLabel


func _ready() -> void:
	back_button.pressed.connect(_on_back_pressed)

	var path: String = Indexer.current_reader_path
	title_label.text = path.get_file()
	text_label.text = Indexer.get_reader_text(path)
	
	title_label.add_theme_color_override("font_color", Color.BLACK)
	text_label.add_theme_color_override("default_color", Color.BLACK)
	text_label.add_theme_color_override("background_color", Color.WHITE)
	#text_label.custom_minimum_size.y = 100
	# --- Nastavení velikosti textu (Font Size) ---
	title_label.add_theme_font_size_override("font_size", 34) # Větší titulek souboru
	text_label.add_theme_font_size_override("font_size", 26)  # Čitelná velikost pro hlavní text

func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/Search.tscn")
