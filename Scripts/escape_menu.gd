extends Control

# ============================================================================
# ESCAPE MENU
# ============================================================================

signal resume_pressed
signal save_pressed
signal load_pressed
signal export_pressed
signal change_data_folder_pressed
@warning_ignore("unused_signal")
@warning_ignore("unused_signal")
signal keybinds_pressed
signal quit_confirmed
signal unsaved_confirmed_load   # User chose to discard changes and load
signal unsaved_confirmed_quit   # User chose to discard changes and quit

@onready var panel: Panel                       = $Panel
@onready var resume_btn: Button                 = %Resume
@onready var save_btn: Button                   = %Save
@onready var load_btn: Button                   = %Load
@onready var keybinds_btn: Button               = %Keybinds
@onready var export_btn: Button                 = %Export
@onready var change_folder_btn: Button          = %ChangeDataFolder
@onready var quit_btn: Button                   = %QuitEditor
@onready var quit_confirm_dialog: Control       = $QuitConfirmDialog
@onready var cancel_quit_btn: Button            = %CancelQuit
@onready var confirm_quit_btn: Button           = %ConfirmQuit
@onready var keybinds_panel: Control            = $KeybindsPanel
@onready var close_keybinds_btn: Button         = %CloseKeybinds
@onready var binds_list: VBoxContainer          = %BindsList
@onready var unsaved_warning: Control           = $UnsavedWarning
@onready var cancel_unsaved_btn: Button         = %CancelUnsaved
@onready var confirm_unsaved_btn: Button        = %ConfirmUnsaved

# Tracks what action triggered the unsaved warning ("load" or "quit")
var _pending_unsaved_action: String = ""

# Each entry: [category_label, [ [display_name, action_name_or_null, static_label_or_null] ] ]
# action_name = rebindable InputMap action. static_label = non-rebindable display text.
const SHORTCUTS: Array = [
	["Camera", [
		["Move Forward",    "cam_move_forward", null],
		["Move Back",       "cam_move_back",    null],
		["Move Left",       "cam_move_left",    null],
		["Move Right",      "cam_move_right",   null],
		["Move Up",         "cam_move_up",      null],
		["Move Down",       "cam_move_down",    null],
		["Look Around",     null,               "MMB drag"],
		["Zoom",            null,               "Scroll wheel"],
		["Reset View",      "reset_view",       null],
		["Reset FOV",       "reset_fov",        null],
	]],
	["Editing", [
		["Place Tile",      null,               "LMB"],
		["Remove Tile",     null,               "RMB"],
		["Toggle Mode",     "toggle_mode",      null],
		["Wireframes",      "toggle_wireframe", null],
		["Toggle Paint",    "toggle_paint",     null],
		["Rotate Tile",     "rotate_tile",      null],
		["Delete Tile",     "delete_tile",      null],
		["Layer Up",        "layer_up",         null],
		["Layer Down",      "layer_down",       null],
		["Flip",            "flip_tile",        null],
	]],
	["Block Types", [
		["Cube",            "tile_type_1",      null],
		["Bevel",           "tile_type_2",      null],
		["Stairs",          "tile_type_3",      null],
	]],
	["Selection", [
		["Copy",            "copy_selection",   null],
		["Paste",           "paste_selection",  null],
	]],
	["File", [
		["Quick Save",      "quick_save",       null],
		["Save As",         "save_as",          null],
		["Load",            "load",             null],
		["Export",          "export",           null],
	]],
]

# Tracks which button is currently listening for a new keypress
var _listening_btn: Button = null
var _listening_action: String = ""


func _input(event: InputEvent) -> void:
	if not visible:
		return
	# If listening for a rebind, intercept all keypresses
	if _listening_btn != null and event is InputEventKey and event.pressed and not event.is_echo():
		_handle_keybind_input(event)
		return
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		if unsaved_warning.visible:
			_close_unsaved_warning()
		elif keybinds_panel.visible:
			_close_keybinds()
		elif quit_confirm_dialog.visible:
			_on_cancel_quit_pressed()
		else:
			close()
			resume_pressed.emit()


func _ready() -> void:
	resume_btn.pressed.connect(_on_resume_pressed)
	save_btn.pressed.connect(_on_save_pressed)
	load_btn.pressed.connect(_on_load_pressed)
	export_btn.pressed.connect(_on_export_pressed)
	keybinds_btn.pressed.connect(_on_keybinds_pressed)
	change_folder_btn.pressed.connect(func() -> void: change_data_folder_pressed.emit())
	quit_btn.pressed.connect(_on_quit_pressed)
	cancel_quit_btn.pressed.connect(_on_cancel_quit_pressed)
	confirm_quit_btn.pressed.connect(_on_confirm_quit_pressed)
	close_keybinds_btn.pressed.connect(_close_keybinds)
	cancel_unsaved_btn.pressed.connect(_close_unsaved_warning)
	confirm_unsaved_btn.pressed.connect(_on_confirm_unsaved_pressed)
	_build_shortcuts_list()


func open() -> void:
	visible = true
	quit_confirm_dialog.visible = false
	keybinds_panel.visible = false
	unsaved_warning.visible = false
	resume_btn.grab_focus()


func close() -> void:
	visible = false
	quit_confirm_dialog.visible = false
	keybinds_panel.visible = false
	unsaved_warning.visible = false


func show_unsaved_warning(action: String) -> void:
	"""Show the unsaved changes warning. action is 'load' or 'quit'."""
	_pending_unsaved_action = action
	quit_confirm_dialog.visible = false
	keybinds_panel.visible = false
	unsaved_warning.visible = true
	confirm_unsaved_btn.grab_focus()


func _close_unsaved_warning() -> void:
	unsaved_warning.visible = false
	_pending_unsaved_action = ""
	resume_btn.grab_focus()


func _on_confirm_unsaved_pressed() -> void:
	unsaved_warning.visible = false
	if _pending_unsaved_action == "load":
		unsaved_confirmed_load.emit()
	elif _pending_unsaved_action == "quit":
		unsaved_confirmed_quit.emit()
	_pending_unsaved_action = ""


func _on_resume_pressed() -> void:
	close()
	resume_pressed.emit()


func _on_save_pressed() -> void:
	close()
	save_pressed.emit()


func _on_load_pressed() -> void:
	# Don't close yet — level_editor may need to show unsaved warning first.
	load_pressed.emit()


func _on_export_pressed() -> void:
	close()
	export_pressed.emit()


func _on_keybinds_pressed() -> void:
	quit_confirm_dialog.visible = false
	unsaved_warning.visible = false
	keybinds_panel.visible = true
	close_keybinds_btn.grab_focus()


func _close_keybinds() -> void:
	_stop_listening()
	keybinds_panel.visible = false
	keybinds_btn.grab_focus()


func _on_quit_pressed() -> void:
	keybinds_panel.visible = false
	unsaved_warning.visible = false
	quit_confirm_dialog.visible = true
	confirm_quit_btn.grab_focus()


func _on_cancel_quit_pressed() -> void:
	quit_confirm_dialog.visible = false
	quit_btn.grab_focus()


func _on_confirm_quit_pressed() -> void:
	quit_confirmed.emit()


func _build_shortcuts_list() -> void:
	for category_entry in SHORTCUTS:
		var category: String = category_entry[0]
		var bindings: Array  = category_entry[1]

		var header: Label = Label.new()
		header.text = category.to_upper()
		header.add_theme_font_size_override("font_size", 11)
		header.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55, 1.0))
		binds_list.add_child(header)

		for binding in bindings:
			var action_name: String  = binding[1] if binding[1] != null else ""
			var static_text: String  = binding[2] if binding[2] != null else ""
			_build_binding_row(binding[0], action_name, static_text)

		var spacer: Control = Control.new()
		spacer.custom_minimum_size = Vector2(0, 6)
		binds_list.add_child(spacer)


func _build_binding_row(label_text: String, action_name: String, static_text: String) -> void:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)

	var action_label: Label = Label.new()
	action_label.text = label_text
	action_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	action_label.add_theme_font_size_override("font_size", 13)
	row.add_child(action_label)

	if action_name == "":
		# Non-rebindable — static label only
		var key_label: Label = Label.new()
		key_label.text = static_text
		key_label.add_theme_font_size_override("font_size", 13)
		key_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6, 1.0))
		key_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(key_label)
	else:
		# Rebindable — button that enters listening mode + reset button
		var bind_btn: Button = Button.new()
		bind_btn.custom_minimum_size = Vector2(110, 0)
		bind_btn.add_theme_font_size_override("font_size", 12)
		_refresh_bind_btn(bind_btn, action_name)

		var captured_action: String = action_name
		bind_btn.pressed.connect(func() -> void:
			_start_listening(bind_btn, captured_action)
		)
		row.add_child(bind_btn)

		var reset_btn: Button = Button.new()
		reset_btn.text = "↺"
		reset_btn.custom_minimum_size = Vector2(28, 0)
		reset_btn.add_theme_font_size_override("font_size", 14)
		reset_btn.tooltip_text = "Reset to default"
		reset_btn.pressed.connect(func() -> void:
			AppConfig.reset_keybinding(captured_action)
			_stop_listening()
			_refresh_bind_btn(bind_btn, captured_action)
		)
		row.add_child(reset_btn)

	binds_list.add_child(row)


func _get_action_key_string(action_name: String) -> String:
	"""Return a human-readable string for the first keyboard event of an action."""
	if not InputMap.has_action(action_name):
		return "?"
	for event in InputMap.action_get_events(action_name):
		if event is InputEventKey:
			return event.as_text().replace(" (Physical)", "")
	return "—"


func _refresh_bind_btn(btn: Button, action_name: String) -> void:
	btn.text = _get_action_key_string(action_name)
	btn.modulate = Color.WHITE


func _start_listening(btn: Button, action_name: String) -> void:
	if _listening_btn != null:
		_stop_listening()
	_listening_btn = btn
	_listening_action = action_name
	btn.text = "Press a key..."
	btn.modulate = Color(1.0, 0.85, 0.3, 1.0)


func _stop_listening() -> void:
	_listening_btn = null
	_listening_action = ""


func _handle_keybind_input(event: InputEventKey) -> void:
	"""Called from _input when in listening mode. Applies or cancels rebind."""
	get_viewport().set_input_as_handled()
	if event.keycode == KEY_ESCAPE:
		# Cancel — restore label
		_refresh_bind_btn(_listening_btn, _listening_action)
		_stop_listening()
		return
	AppConfig.set_keybinding(_listening_action, event)
	_refresh_bind_btn(_listening_btn, _listening_action)
	_stop_listening()
