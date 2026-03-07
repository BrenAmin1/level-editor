extends Control

# ============================================================================
# CONSOLE PANEL UI
# ============================================================================
# Instance console_panel.tscn as a child of UI in level_editor.tscn.
# Add "console_toggle" action to Input Map (suggested: backtick `)
#
# In level_editor.gd _ready(), add:
#   console_panel.setup()
# ============================================================================

var LINE_COLORS: Dictionary  # populated in _ready()

const CONSOLE_HEIGHT := 300.0

@onready var log_container: VBoxContainer = %LogContainer
@onready var input_field: LineEdit        = %InputField
@onready var scroll_container: ScrollContainer = $VBoxContainer/ScrollContainer

var _camera: CameraController = null

# Command history navigation
var _history_index: int = -1


func setup(camera: CameraController) -> void:
	_camera = camera


func _ready() -> void:
	LINE_COLORS = {
		Console.Level.INFO:   Color(0.85, 0.85, 0.85, 1.0),
		Console.Level.WARN:   Color(1.0,  0.82, 0.3,  1.0),
		Console.Level.ERROR:  Color(1.0,  0.35, 0.35, 1.0),
		Console.Level.SYSTEM: Color(0.5,  0.9,  0.5,  1.0),
	}
	# Connect Console singleton signals
	Console.message_logged.connect(_on_message_logged)
	input_field.text_submitted.connect(_on_input_submitted)

	# Print existing entries (e.g. from before the panel existed)
	for entry in Console.entries:
		_append_entry(entry)

	Console.system("Console ready. Type 'help' for commands.")


func _unhandled_input(event: InputEvent) -> void:
	# Toggle can fire from anywhere
	if event is InputEventKey and event.pressed and not event.is_echo():
		if Input.is_action_just_pressed("console_toggle"):
			get_viewport().set_input_as_handled()
			_toggle()
			return

	if not visible:
		return

	# Handle navigation keys — LineEdit doesn't use these
	if event is InputEventKey and event.pressed and not event.is_echo():
		if event.keycode == KEY_UP:
			get_viewport().set_input_as_handled()
			_navigate_history(-1)
		elif event.keycode == KEY_DOWN:
			get_viewport().set_input_as_handled()
			_navigate_history(1)
		elif event.keycode == KEY_ESCAPE:
			get_viewport().set_input_as_handled()
			_hide()


func _toggle() -> void:
	if visible:
		_hide()
	else:
		_show()


func _show() -> void:
	visible = true
	input_field.clear()
	_history_index = -1
	_scroll_to_bottom()
	if _camera:
		_camera.console_open = true
	# Defer focus so the backtick keyup event doesn't immediately unfocus the field
	call_deferred("_focus_input")


func _focus_input() -> void:
	input_field.grab_focus()


func _hide() -> void:
	visible = false
	input_field.clear()
	if _camera:
		_camera.console_open = false


func _on_input_submitted(text: String) -> void:
	_history_index = -1
	Console.execute(text)
	input_field.clear()
	_scroll_to_bottom()


func _on_message_logged(entry: Dictionary) -> void:
	if entry.get("clear", false):
		for child in log_container.get_children():
			child.queue_free()
		return
	_append_entry(entry)
	_scroll_to_bottom()


func _append_entry(entry: Dictionary) -> void:
	var label := RichTextLabel.new()
	label.bbcode_enabled = false
	label.fit_content = true
	label.scroll_active = false
	label.add_theme_font_size_override("normal_font_size", 12)
	label.add_theme_color_override("default_color", LINE_COLORS.get(entry.level, Color.WHITE))

	var timestamp: String = entry.get("timestamp", "")
	if timestamp != "":
		label.text = "[%s] %s" % [timestamp, entry.text]
	else:
		label.text = entry.text

	log_container.add_child(label)

	# Trim old lines if over limit
	if log_container.get_child_count() > Console.MAX_HISTORY:
		log_container.get_child(0).queue_free()


func _scroll_to_bottom() -> void:
	# Defer so layout is complete before scrolling
	call_deferred("_do_scroll")


func _do_scroll() -> void:
	@warning_ignore("narrowing_conversion")
	scroll_container.scroll_vertical = scroll_container.get_v_scroll_bar().max_value


func _navigate_history(direction: int) -> void:
	var history: Array[String] = Console.cmd_history
	if history.is_empty():
		return

	_history_index = int(clamp(_history_index - direction, 0, history.size() - 1))
	input_field.text = history[history.size() - 1 - _history_index]
	input_field.set_caret_column(input_field.text.length())
