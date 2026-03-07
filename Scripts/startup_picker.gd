extends Control

# ============================================================================
# STARTUP PICKER
# ============================================================================
# Shown on launch (after first-launch dialog if needed).
# Wire from level_editor._ready():
#
#   startup_picker.new_level_pressed.connect(_on_startup_new)
#   startup_picker.open_pressed.connect(show_load_dialog)
#   startup_picker.file_selected.connect(_on_startup_file_selected)
#   startup_picker.quit_pressed.connect(get_tree().quit)
# ============================================================================

signal new_level_pressed
signal open_pressed
signal file_selected(path: String)
signal quit_pressed

@onready var recent_list: VBoxContainer  = %RecentList
@onready var no_recents_label: Label     = %NoRecentsLabel
@onready var new_level_btn: Button       = %NewLevel
@onready var open_level_btn: Button      = %OpenLevel
@onready var quit_btn: Button            = %QuitBtn

# StyleBoxes for recent file buttons — set in _ready from theme
var _recent_normal: StyleBoxFlat
var _recent_hover: StyleBoxFlat


func _ready() -> void:
	new_level_btn.pressed.connect(func() -> void: new_level_pressed.emit())
	open_level_btn.pressed.connect(func() -> void: open_pressed.emit())
	quit_btn.pressed.connect(func() -> void: quit_pressed.emit())

	# Grab styleboxes from the first sub-resource set (reuse from scene)
	_recent_normal = new_level_btn.get_theme_stylebox("normal").duplicate()
	_recent_hover  = new_level_btn.get_theme_stylebox("hover").duplicate()

	_populate_recent_files()


func _populate_recent_files() -> void:
	# Clear existing entries except the no-recents label
	for child in recent_list.get_children():
		if child != no_recents_label:
			child.queue_free()

	var files: Array[String] = AppConfig.get_valid_recent_files()

	if files.is_empty():
		no_recents_label.visible = true
		return

	no_recents_label.visible = false

	for path in files:
		var btn: Button = Button.new()
		btn.text = path.get_file().get_basename()
		btn.tooltip_text = path
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.clip_text = true
		btn.add_theme_stylebox_override("normal",  _recent_normal)
		btn.add_theme_stylebox_override("hover",   _recent_hover)
		btn.add_theme_stylebox_override("pressed", _recent_normal)
		btn.add_theme_stylebox_override("focus",   _recent_normal)
		btn.add_theme_font_size_override("font_size", 13)

		# Capture path for lambda
		var captured_path: String = path
		btn.pressed.connect(func() -> void: file_selected.emit(captured_path))
		recent_list.add_child(btn)
