extends Node

# ============================================================================
# APP CONFIG — Autoload Singleton
# ============================================================================
# Central store for all user preferences and derived paths.
#
# Config file lives at:
#   user://config.json   (i.e. %APPDATA%/Rain Level Editor/config.json)
#
# Everything else lives under the user-chosen data_directory, which defaults
# to Documents/Rain Level Editor/ on first launch.
#
# Access paths via:
#   AppConfig.saves_dir       → ".../Rain Level Editor/saved_levels/"
#   AppConfig.exports_dir     → ".../Rain Level Editor/exports/"
#   AppConfig.textures_dir    → ".../Rain Level Editor/textures/"
#   AppConfig.palettes_dir    → ".../Rain Level Editor/palettes/"
# ============================================================================

# ============================================================================
# SIGNALS
# ============================================================================

# Emitted after config is saved (e.g. so UI can react to data_directory change)
signal config_saved
# Emitted on first launch before config exists — caller should show setup dialog
signal first_launch_detected

# ============================================================================
# CONSTANTS
# ============================================================================

const CONFIG_PATH: String        = "user://config.json"
const APP_FOLDER_NAME: String    = "Rain Level Editor"
const DEFAULT_SUBFOLDERS: Array[String] = ["saved_levels", "exports", "textures", "palettes", "temp"]

# ============================================================================
# RUNTIME STATE
# ============================================================================

# Resolved absolute OS path the user chose (or the default).
var data_directory: String = ""

# Keybinding overrides. Keys match InputMap action names.
# Only actions the user has changed are stored here.
var keybindings: Dictionary = {}

# Most recently opened/saved level paths, newest first. Max 5 entries.
var recent_files: Array[String] = []

# True if this is the first time the app has launched (no config.json found).
var is_first_launch: bool = false

# ============================================================================
# DERIVED PATH PROPERTIES
# ============================================================================

var saves_dir:    String: get = _get_saves_dir
var exports_dir:  String: get = _get_exports_dir
var textures_dir: String: get = _get_textures_dir
var palettes_dir: String: get = _get_palettes_dir
var temp_dir:     String: get = _get_temp_dir

func _get_saves_dir()    -> String: return data_directory.path_join("saved_levels") + "/"
func _get_exports_dir()  -> String: return data_directory.path_join("exports") + "/"
func _get_textures_dir() -> String: return data_directory.path_join("textures") + "/"
func _get_palettes_dir() -> String: return data_directory.path_join("palettes") + "/"
func _get_temp_dir()     -> String: return data_directory.path_join("temp") + "/"

# ============================================================================
# LIFECYCLE
# ============================================================================

func _ready() -> void:
	if FileAccess.file_exists(CONFIG_PATH):
		_load_config()
	else:
		is_first_launch = true
		data_directory = _default_data_directory()
		# Defer so the scene tree is ready before any dialog is shown.
		call_deferred("_on_first_launch")

	if not is_first_launch:
		_ensure_directories()
	_apply_keybindings()


func _on_first_launch() -> void:
	first_launch_detected.emit()


# ============================================================================
# PUBLIC API
# ============================================================================

func set_data_directory(path: String) -> void:
	"""Set a new data directory and persist it. Creates subdirectories."""
	data_directory = path
	_ensure_directories()
	save_config()


func set_keybinding(action: String, event: InputEvent) -> void:
	"""Override a single action's keybinding and persist."""
	keybindings[action] = _serialize_input_event(event)
	_apply_keybinding(action, event)
	save_config()


func reset_keybinding(action: String) -> void:
	"""Remove a keybinding override, reverting to project.godot default."""
	keybindings.erase(action)
	_reset_action_to_default(action)
	save_config()


func add_recent_file(path: String) -> void:
	"""Add a path to the recent files list, newest first. Removes duplicates and caps at 5."""
	recent_files.erase(path)  # Remove if already present
	recent_files.push_front(path)
	if recent_files.size() > 5:
		recent_files.resize(5)
	save_config()


func remove_recent_file(path: String) -> void:
	"""Remove a path from recent files (e.g. file no longer exists)."""
	recent_files.erase(path)
	save_config()


func get_valid_recent_files() -> Array[String]:
	"""Return only recent files that exist on disk, removing stale entries."""
	var valid: Array[String] = []
	var removed: bool = false
	for path in recent_files:
		if FileAccess.file_exists(path):
			valid.append(path)
		else:
			removed = true
	if removed:
		recent_files = valid
		save_config()
	return valid


func save_config() -> void:
	"""Write current config to user://config.json."""
	var data: Dictionary = {
		"data_directory": data_directory,
		"keybindings":    keybindings,
		"recent_files":   recent_files,
	}
	var json_string: String = JSON.stringify(data, "\t")

	# Atomic write: temp file then rename so a force-kill never corrupts config.
	var tmp: String = CONFIG_PATH + ".tmp"
	var f: FileAccess = FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_error("AppConfig: failed to write temp config at " + tmp)
		return
	f.store_string(json_string)
	f.close()

	var dir: DirAccess = DirAccess.open("user://")
	if dir == null or dir.rename(tmp, CONFIG_PATH) != OK:
		push_error("AppConfig: failed to rename temp config to " + CONFIG_PATH)
		return

	config_saved.emit()


func copy_texture_to_data_dir(source_path: String) -> String:
	"""
	Copy an image file from source_path into the app textures directory.
	- If the file is already inside the textures directory, return it as-is.
	- If a file with the same name already exists there, reuse it (no duplicate).
	- Otherwise copy it in.
	Returns the destination path on success, or "" on failure.
	"""
	# Already in the textures folder — nothing to do.
	if source_path.begins_with(textures_dir):
		return source_path

	var dest: String = textures_dir + source_path.get_file()

	# Same filename already copied — reuse it.
	if FileAccess.file_exists(dest):
		return dest

	var err: Error = DirAccess.copy_absolute(source_path, dest)
	if err != OK:
		push_error("AppConfig: failed to copy texture '%s' to '%s' (error %d)" \
				% [source_path, dest, err])
		return ""
	return dest


# ============================================================================
# PRIVATE — CONFIG I/O
# ============================================================================

func _load_config() -> void:
	var f: FileAccess = FileAccess.open(CONFIG_PATH, FileAccess.READ)
	if f == null:
		push_error("AppConfig: could not open config at " + CONFIG_PATH)
		data_directory = _default_data_directory()
		return

	var text: String   = f.get_as_text()
	f.close()

	var parsed: Variant = JSON.parse_string(text)
	if parsed == null or not parsed is Dictionary:
		push_error("AppConfig: config JSON is invalid, using defaults")
		data_directory = _default_data_directory()
		return

	data_directory = parsed.get("data_directory", _default_data_directory())
	keybindings    = parsed.get("keybindings", {})
	recent_files   = Array(parsed.get("recent_files", []), TYPE_STRING, "", null)


func _default_data_directory() -> String:
	return OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS).path_join(APP_FOLDER_NAME)


func _ensure_directories() -> void:
	"""Create data_directory and all required subdirectories if missing."""
	for sub in DEFAULT_SUBFOLDERS:
		var path: String = data_directory.path_join(sub)
		if not DirAccess.dir_exists_absolute(path):
			var err: Error = DirAccess.make_dir_recursive_absolute(path)
			if err != OK:
				push_error("AppConfig: failed to create directory: " + path)


# ============================================================================
# PRIVATE — KEYBINDINGS
# ============================================================================

func _apply_keybindings() -> void:
	"""Apply all stored keybinding overrides to the InputMap."""
	for action in keybindings:
		var event: InputEvent = _deserialize_input_event(keybindings[action])
		if event:
			_apply_keybinding(action, event)


func _apply_keybinding(action: String, event: InputEvent) -> void:
	if not InputMap.has_action(action):
		push_warning("AppConfig: unknown action '" + action + "', skipping")
		return
	InputMap.action_erase_events(action)
	InputMap.action_add_event(action, event)


func _reset_action_to_default(action: String) -> void:
	"""Restore an action to whatever is defined in project.godot."""
	InputMap.load_from_project_settings()
	# Re-apply all OTHER stored overrides since load_from_project_settings resets all.
	for a in keybindings:
		if a != action:
			var event: InputEvent = _deserialize_input_event(keybindings[a])
			if event:
				_apply_keybinding(a, event)


# ============================================================================
# PRIVATE — INPUT EVENT SERIALIZATION
# ============================================================================
# Stores only keyboard shortcuts for now. Extend _serialize/_deserialize
# if you later support mouse buttons or gamepad bindings.

func _serialize_input_event(event: InputEvent) -> Dictionary:
	if event is InputEventKey:
		return {
			"type":             "key",
			"keycode":          event.keycode,
			"physical_keycode": event.physical_keycode,
			"ctrl":             event.ctrl_pressed,
			"shift":            event.shift_pressed,
			"alt":              event.alt_pressed,
		}
	push_warning("AppConfig: unsupported InputEvent type for serialization")
	return {}


func _deserialize_input_event(data: Dictionary) -> InputEvent:
	if data.get("type", "") == "key":
		var event: InputEventKey = InputEventKey.new()
		event.keycode            = data.get("keycode", 0)
		event.physical_keycode   = data.get("physical_keycode", 0)
		event.ctrl_pressed       = data.get("ctrl", false)
		event.shift_pressed      = data.get("shift", false)
		event.alt_pressed        = data.get("alt", false)
		return event
	return null
