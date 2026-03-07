extends Node

# ============================================================================
# CONSOLE AUTOLOAD
# ============================================================================
# Add as autoload in Project Settings → Autoload, name it "Console".
#
# Usage from any script:
#   Console.info("message")
#   Console.warn("something odd")
#   Console.error("something broke")
#   Console.register_command("my_cmd", func(args): ..., "Description")
# ============================================================================

signal message_logged(entry: Dictionary)  # {text, level, timestamp}

enum Level { INFO, WARN, ERROR, SYSTEM }

const MAX_HISTORY := 200  # Max log entries kept in memory
const MAX_CMD_HISTORY := 50  # Max command history entries

# Log entries: Array of {text: String, level: Level, timestamp: String}
var entries: Array = []

# Command history for up/down arrow cycling
var cmd_history: Array[String] = []

# Registered commands: action_name -> {callable: Callable, description: String}
var _commands: Dictionary = {}


func _ready() -> void:
	_register_builtins()


# ============================================================================
# LOGGING
# ============================================================================

func info(text: Variant, v2: Variant = "", v3: Variant = "", v4: Variant = "", v5: Variant = "", v6: Variant = "", v7: Variant = "", v8: Variant = "", v9: Variant = "", v10: Variant = "") -> void:
	_push(str(text) + str(v2) + str(v3) + str(v4) + str(v5) + str(v6) + str(v7) + str(v8) + str(v9) + str(v10), Level.INFO)


func warn(text: Variant, v2: Variant = "", v3: Variant = "", v4: Variant = "", v5: Variant = "", v6: Variant = "", v7: Variant = "", v8: Variant = "", v9: Variant = "", v10: Variant = "") -> void:
	_push(str(text) + str(v2) + str(v3) + str(v4) + str(v5) + str(v6) + str(v7) + str(v8) + str(v9) + str(v10), Level.WARN)


func error(text: Variant, v2: Variant = "", v3: Variant = "", v4: Variant = "", v5: Variant = "", v6: Variant = "", v7: Variant = "", v8: Variant = "", v9: Variant = "", v10: Variant = "") -> void:
	_push(str(text) + str(v2) + str(v3) + str(v4) + str(v5) + str(v6) + str(v7) + str(v8) + str(v9) + str(v10), Level.ERROR)


func system(text: String) -> void:
	_push(text, Level.SYSTEM)


func clear() -> void:
	entries.clear()
	message_logged.emit({text = "", level = Level.SYSTEM, timestamp = "", clear = true})


func _push(text: String, level: Level) -> void:
	var entry := {
		text      = text,
		level     = level,
		timestamp = Time.get_time_string_from_system(),
		clear     = false,
	}
	entries.append(entry)
	if entries.size() > MAX_HISTORY:
		entries.pop_front()
	# Use call_deferred so thread-originated logs don't crash on signal emit
	call_deferred("emit_signal", "message_logged", entry)
	# Mirror to Godot output panel
	match level:
		Level.WARN:   push_warning("[Console] " + text)
		Level.ERROR:  push_error("[Console] " + text)
		_:            print("[Console] " + text)


# ============================================================================
# COMMANDS
# ============================================================================

func register_command(cmd_name: String, callable: Callable, description: String = "") -> void:
	_commands[cmd_name.to_lower()] = {"callable": callable, "description": description}


func execute(raw: String) -> void:
	"""Parse and run a command string. Called by the console UI on Enter."""
	raw = raw.strip_edges()
	if raw.is_empty():
		return

	# Add to command history
	if cmd_history.is_empty() or cmd_history.back() != raw:
		cmd_history.append(raw)
		if cmd_history.size() > MAX_CMD_HISTORY:
			cmd_history.pop_front()

	system("> " + raw)

	var parts := raw.split(" ", false)
	var cmd_name := parts[0].to_lower()
	var args := parts.slice(1)

	if not _commands.has(cmd_name):
		error("Unknown command: '%s'. Type 'help' for a list." % cmd_name)
		return

	_commands[cmd_name]["callable"].call(args)


# ============================================================================
# BUILT-IN COMMANDS
# ============================================================================

func _register_builtins() -> void:
	register_command("help",            _cmd_help,            "List all available commands")
	register_command("clear",           _cmd_clear,           "Clear the console")
	register_command("quit",            _cmd_quit,            "Quit the application")
	register_command("version",         _cmd_version,         "Print app version")
	register_command("enable_logging",  _cmd_enable_logging,  "Enable Godot file logging to user://logs/")
	register_command("disable_logging", _cmd_disable_logging, "Disable Godot file logging")
	register_command("log_path",        _cmd_log_path,        "Print the path to the Godot log file")
	register_command("data_dir",        _cmd_data_dir,        "Print the current data directory")
	register_command("set_data_dir",    _cmd_set_data_dir,    "Set the data directory. Usage: set_data_dir <path>")
	register_command("logging",          _cmd_logging,         "Show or set file logging state. Usage: logging [on|off]")
	# Editor commands registered later by level_editor._ready() via register_command()


func _cmd_help(_args: Array) -> void:
	info("Available commands:")
	for cmd_name in _commands.keys():
		var desc: String = _commands[cmd_name]["description"]
		info("  %-20s %s" % [cmd_name, desc])


func _cmd_clear(_args: Array) -> void:
	clear()


func _cmd_quit(_args: Array) -> void:
	system("Goodbye.")
	get_tree().quit()


func _cmd_version(_args: Array) -> void:
	info("Rain Level Editor v%s" % ProjectSettings.get_setting("application/config/version", "unknown"))


func _cmd_enable_logging(_args: Array) -> void:
	ProjectSettings.set_setting("application/run/flush_stdout_on_print", true)
	info("File logging enabled. Log path: %s" % _get_log_path())


func _cmd_disable_logging(_args: Array) -> void:
	ProjectSettings.set_setting("application/run/flush_stdout_on_print", false)
	info("File logging disabled.")


func _cmd_log_path(_args: Array) -> void:
	info(_get_log_path())


func _cmd_data_dir(_args: Array) -> void:
	info(AppConfig.data_directory)


func _cmd_set_data_dir(args: Array) -> void:
	if args.is_empty():
		error("Usage: set_data_dir <path>")
		return
	var path := " ".join(args)  # Rejoin in case path has spaces
	if not DirAccess.dir_exists_absolute(path):
		error("Directory does not exist: " + path)
		return
	AppConfig.data_directory = path
	AppConfig.save_config()
	info("Data directory set to: " + path)


func _cmd_logging(args: Array) -> void:
	if args.is_empty():
		var enabled: bool = ProjectSettings.get_setting("application/run/flush_stdout_on_print", false)
		info("File logging is currently: ", "on" if enabled else "off")
		info("Log path: ", _get_log_path())
		return
	var val = args[0].to_lower()
	if val == "on":
		ProjectSettings.set_setting("application/run/flush_stdout_on_print", true)
		info("File logging enabled. Log path: ", _get_log_path())
	elif val == "off":
		ProjectSettings.set_setting("application/run/flush_stdout_on_print", false)
		info("File logging disabled.")
	else:
		error("Usage: logging [on|off]")


func _get_log_path() -> String:
	return OS.get_user_data_dir() + "/logs/godot.log"
