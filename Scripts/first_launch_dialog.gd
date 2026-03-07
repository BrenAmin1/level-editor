extends Window

# ============================================================================
# FIRST LAUNCH DIALOG
# ============================================================================
# Shown once when no config.json exists. Lets the user choose where their
# levels, exports, textures, and palettes will be stored.
#
# Wire up in level_editor.gd:
#   AppConfig.first_launch_detected.connect(_on_first_launch)
#
#   func _on_first_launch() -> void:
#       var dialog: FirstLaunchDialog = preload("res://Scenes/first_launch_dialog.tscn").instantiate()
#       add_child(dialog)
#       dialog.popup_centered()
# ============================================================================

# Emitted once the user confirms their chosen directory.
signal setup_confirmed

@onready var path_label: Label       = %PathLabel
@onready var browse_button: Button   = %BrowseButton
@onready var confirm_button: Button  = %ConfirmButton

var _chosen_path: String = ""
var _folder_dialog: FileDialog


func _ready() -> void:
	# Block interaction with the editor behind this window.
	exclusive = true
	unresizable = true
	close_requested.connect(_on_close_requested)

	_chosen_path = AppConfig.data_directory
	_update_path_label()

	browse_button.pressed.connect(_on_browse_pressed)
	confirm_button.pressed.connect(_on_confirm_pressed)

	_setup_folder_dialog()


func _setup_folder_dialog() -> void:
	_folder_dialog = FileDialog.new()
	add_child(_folder_dialog)
	_folder_dialog.file_mode    = FileDialog.FILE_MODE_OPEN_DIR
	_folder_dialog.access       = FileDialog.ACCESS_FILESYSTEM
	_folder_dialog.use_native_dialog = true
	_folder_dialog.current_dir  = _chosen_path
	_folder_dialog.dir_selected.connect(_on_folder_selected)


func _on_browse_pressed() -> void:
	# Re-set current_dir just before opening — native dialogs may ignore it,
	# but Godot's built-in dialog respects it.
	_folder_dialog.current_dir = OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	_folder_dialog.popup_centered(Vector2i(800, 600))


func _on_folder_selected(path: String) -> void:
	# User picked a folder — append the app name so we don't dump files
	# directly into e.g. Documents root.
	if path.get_file() != AppConfig.APP_FOLDER_NAME:
		_chosen_path = path.path_join(AppConfig.APP_FOLDER_NAME)
	else:
		_chosen_path = path
	_update_path_label()


func _on_confirm_pressed() -> void:
	AppConfig.set_data_directory(_chosen_path)
	setup_confirmed.emit()
	queue_free()


func _on_close_requested() -> void:
	# Don't allow dismissing without confirming — just use the default path.
	_on_confirm_pressed()


func _update_path_label() -> void:
	if path_label:
		path_label.text = _chosen_path
