extends Node3D

# ============================================================================
# COMPONENTS
# ============================================================================
@onready var camera: CameraController = $Camera3D
@onready var grid_visualizer: GridVisualizer = $GridVisualizer
@onready var cursor_visualizer: CursorVisualizer = $CursorVisualizer
@onready var material_palette: FoldableContainer = $UI/MaterialPalette
@onready var right_side_menu: VBoxContainer = $UI/RightSideMenu
@onready var block_menu: BlockMenu = $UI/BlockMenu
@onready var escape_menu: Control = $UI/EscapeMenu
@onready var startup_picker: Control = $UI/StartupPicker
@onready var console_panel: Control = $UI/ConsolePanel

var tilemap: TileMap3D
var input_handler: InputHandler
var selection_manager: SelectionManager
var y_level_manager: YLevelManager
var undo_redo: UndoRedoManager

# ============================================================================
# EDITOR STATE
# ============================================================================
enum EditorMode { EDIT, SELECT }
var current_mode: EditorMode = EditorMode.EDIT
var current_tile_type = 0
var current_y_level = 0
var grid_size = 1.0
var rotation_increment: float = 15.0  # degrees
var current_save_file: String = ""  # Tracks the currently loaded/saved file
var has_unsaved_changes: bool = false
var _loading_from_startup_picker: bool = false
var window_has_focus: bool = true
var is_popup_open: bool = false  # True when any popup is open (derived from _popup_open_count)
var _popup_open_count: int = 0    # Number of popups currently open
var is_exporting: bool = false   # Block input while export is in progress
var current_painting_material: StandardMaterial3D = null
var current_painting_material_index: int = -1
var current_stair_steps: int = 4  # Number of steps for procedural stairs (min 2, max 16)

# ============================================================================
# EXPORT THREADING
# ============================================================================
var _export_thread: Thread = null
var _export_overlay: CanvasLayer = null
var _export_label: Label = null
var _export_bar: ColorRect = null
var _export_bar_fill: ColorRect = null
var _export_pct_label: Label = null

# ============================================================================
# AUTOSAVE
# ============================================================================
# Every AUTOSAVE_INTERVAL seconds (when safe) we do two things:
#   1. Overwrite current_save_file if one exists — same as Ctrl+S.
#   2. Write autosave.tmp — a crash-recovery file deleted on any clean exit.
#
# On launch, if autosave.tmp exists the startup picker shows a recovery prompt.
# The .tmp is never shown in the load dialog (filtered to *.level only).
const AUTOSAVE_INTERVAL: float = 120.0
var _autosave_timer: float = AUTOSAVE_INTERVAL
var _autosave_enabled: bool = true

# Small bottom-right indicator shown briefly after each autosave (kept for compat)
var _autosave_indicator: Label = null
@warning_ignore("unused_private_class_variable")
var _autosave_indicator_tween: Tween = null

# ============================================================================
# TOP-LEFT HUD
# ============================================================================
var _hud_paint_label: Label = null
var _hud_save_label: Label = null
var _hud_autosave_label: Label = null
@warning_ignore("unused_private_class_variable")
var _hud_save_tween: Tween = null
@warning_ignore("unused_private_class_variable")
var _hud_autosave_tween: Tween = null

# ============================================================================
# SETTINGS
# ============================================================================
@export var grid_range: int = 100

# ============================================================================
# MATERIALS
# ============================================================================
const GRASS = preload("uid://djotdj5tifi3y")
const DIRT = preload("uid://bxl8k6n4i56yn")

# ============================================================================
# INITIALIZATION
# ============================================================================

const FirstLaunchDialog = preload("res://Scenes/first_launch_dialog.tscn")

func _ready() -> void:
	# Disable auto-quit so we can cleanly stop threads before the process exits.
	get_tree().set_auto_accept_quit(false)

	# Show first-launch setup dialog if this is the user's first run.
	if AppConfig.is_first_launch:
		AppConfig.first_launch_detected.connect(_on_first_launch)

	# Directories are created by AppConfig.set_data_directory() on confirm — skip on first launch
	if not AppConfig.is_first_launch:
		LevelSaveLoad.ensure_save_directory()

	# Connect FileDialog signals
	export_dialog.export_confirmed.connect(_on_export_confirmed)
	save_dialog.save_confirmed.connect(_on_save_confirmed)
	load_dialog.load_confirmed.connect(_on_load_confirmed)

	_setup_file_dialogs()
	_show_startup_picker()
	console_panel.setup(camera)
	_register_console_commands()
	_setup_autosave_indicator()

	# Initialize TileMap3D
	tilemap = TileMap3D.new(grid_size)
	tilemap.set_parent(self)
	tilemap.set_offset_provider(Callable(self, "get_y_level_offset"))
	tilemap.set_material_palette_reference(material_palette)

	# Load custom meshes
	tilemap.load_obj_for_tile_type(0, "res://cubes/cube_bulge.obj")
	tilemap.set_custom_material(0, 0, GRASS)
	tilemap.set_custom_material(0, 1, DIRT)
	tilemap.set_custom_material(0, 2, DIRT)
	tilemap.load_obj_for_tile_type(1, "res://cubes/half_bevel.obj")
	tilemap.set_custom_material(1, 0, GRASS)
	tilemap.set_custom_material(1, 1, DIRT)
	tilemap.set_custom_material(1, 2, DIRT)

	var surfaces = tilemap.get_surface_count(3)
	Console.info("Loaded ", surfaces, " surfaces")
	for i in range(surfaces):
		var arrays = tilemap.custom_meshes[3].surface_get_arrays(i)
		var indices = arrays[Mesh.ARRAY_INDEX]
		Console.info("  Surface ", i, ": ", indices.size() / 3, " triangles")

	# Initialize components
	y_level_manager = YLevelManager.new()
	y_level_manager.setup(tilemap, grid_visualizer)

	selection_manager = SelectionManager.new()
	selection_manager.setup(tilemap, camera, y_level_manager, grid_size, grid_range, self)

	input_handler = InputHandler.new()
	input_handler.setup(self, camera, tilemap, cursor_visualizer, selection_manager,
						y_level_manager, grid_size, grid_range)
	input_handler.set_material_palette_reference(material_palette)
	selection_manager.set_material_palette_reference(material_palette)

	# Initialize undo/redo and wire into components
	undo_redo = UndoRedoManager.new()
	undo_redo.setup(tilemap, material_palette)
	undo_redo.action_recorded.connect(func() -> void: has_unsaved_changes = true)
	input_handler.set_undo_redo(undo_redo)
	selection_manager.set_undo_redo(undo_redo)
	input_handler.paint_mode_changed.connect(_on_paint_mode_changed)

	get_window().focus_entered.connect(_on_window_focus_entered)
	get_window().focus_exited.connect(_on_window_focus_exited)

	# Connect material palette signals
	if material_palette:
		material_palette.ui_hover_changed.connect(_on_material_palette_hover_changed)
		material_palette.popup_state_changed.connect(_on_popup_state_changed)
		material_palette.material_selected.connect(_on_material_selected)

	if right_side_menu:
		var x_spin = right_side_menu.get_node("OffsetFold/PanelContainer/OffsetVContain/XSpin")
		var z_spin = right_side_menu.get_node("OffsetFold/PanelContainer/OffsetVContain/ZSpin")
		input_handler.register_focus_control(x_spin)
		input_handler.register_focus_control(z_spin)

	_setup_block_menu()
	_setup_escape_menu()

	Console.info("Mode: EDIT (Press TAB to toggle)")
	Console.info("\nSave/Load Controls:")
	Console.info("  Ctrl, S - Quick save (saves to current file, or opens Save As if none)")
	Console.info("  Ctrl, Shift, S - Save as... (opens dialog, becomes new quick save target)")
	Console.info("  Ctrl, L - Load level (opens dialog, becomes new quick save target)")
	Console.info("  Ctrl, E - Export mesh (opens dialog with format options)")
	Console.info("\nEdit Controls:")
	Console.info("  Ctrl, Z - Undo")
	Console.info("  Ctrl, Y / Ctrl, Shift, Z - Redo")
	Console.info("\nSelect Mode Controls (TAB to enter):")
	Console.info("  Ctrl, C - Copy selection")
	Console.info("  Ctrl, V - Paste at cursor")
	Console.info("\nPaint Controls:")
	Console.info("  P - Toggle paint mode (change materials without replacing tiles)")
	Console.info("\nAutosave: every ", AUTOSAVE_INTERVAL, "s (type 'autosave' for info)")


# ============================================================================
# STARTUP PICKER + RECOVERY
# ============================================================================

func _show_startup_picker() -> void:
	if AppConfig.is_first_launch:
		var fld_node: Window = get_node_or_null("%FirstLaunchDialog")
		if fld_node:
			fld_node.setup_confirmed.connect(_show_startup_picker, CONNECT_ONE_SHOT)
			return
	startup_picker.visible = true
	_on_popup_state_changed(true)
	_setup_startup_picker()

	# Show recovery prompt if a crash left a .tmp behind
	if FileAccess.file_exists(_get_tmp_path()):
		startup_picker.show_recovery_prompt()


func _setup_startup_picker() -> void:
	# Guard against double-connection
	if startup_picker.quit_pressed.is_connected(_shutdown):
		return
	startup_picker.new_level_pressed.connect(func() -> void:
		startup_picker.visible = false
		_on_popup_state_changed(false)
	)
	startup_picker.open_pressed.connect(func() -> void:
		_loading_from_startup_picker = true
		show_load_dialog()
	)
	startup_picker.file_selected.connect(func(path: String) -> void:
		startup_picker.visible = false
		_on_popup_state_changed(false)
		_begin_loading()
		call_deferred("_do_load_read", path)
	)
	startup_picker.quit_pressed.connect(_shutdown)
	startup_picker.recovery_confirmed.connect(_on_recovery_confirmed)
	startup_picker.recovery_discarded.connect(_on_recovery_discarded)


func _on_recovery_confirmed() -> void:
	"""User chose to recover — load the .tmp file as if it were a normal level."""
	var tmp := _get_tmp_path()
	if not FileAccess.file_exists(tmp):
		Console.warn("[Recovery] Recovery file not found: ", tmp)
		return
	startup_picker.visible = false
	_on_popup_state_changed(false)
	_begin_loading()
	call_deferred("_do_load_read", tmp)


func _on_recovery_discarded() -> void:
	"""User chose to discard — delete the .tmp and continue with a fresh session."""
	_delete_tmp()
	Console.info("[Recovery] Discarded recovery file.")


# ============================================================================
# AUTOSAVE HELPERS
# ============================================================================

func _get_tmp_path() -> String:
	return AppConfig.temp_dir + "autosave.tmp"


func _delete_tmp() -> void:
	var tmp := _get_tmp_path()
	if FileAccess.file_exists(tmp):
		DirAccess.remove_absolute(tmp)


func _setup_autosave_indicator() -> void:
	"""Build the top-left HUD stack (paint mode, save, autosave) and the
	now-unused bottom-right indicator (kept so _show_autosave_indicator still works)."""
	# ── Top-left HUD ─────────────────────────────────────────────────────────
	var hud := VBoxContainer.new()
	hud.set_anchors_preset(Control.PRESET_TOP_LEFT)
	hud.position = Vector2(10, 10)
	hud.add_theme_constant_override("separation", 3)
	$UI.add_child(hud)

	_hud_paint_label = Label.new()
	_hud_paint_label.add_theme_font_size_override("font_size", 12)
	_hud_paint_label.text = "Paint Mode"
	hud.add_child(_hud_paint_label)
	_update_paint_hud(false)  # start dimmed

	_hud_save_label = Label.new()
	_hud_save_label.add_theme_font_size_override("font_size", 12)
	_hud_save_label.modulate.a = 0.0
	hud.add_child(_hud_save_label)

	_hud_autosave_label = Label.new()
	_hud_autosave_label.add_theme_font_size_override("font_size", 12)
	_hud_autosave_label.modulate.a = 0.0
	hud.add_child(_hud_autosave_label)

	# ── Legacy bottom-right indicator (kept so existing call sites still work) ─
	_autosave_indicator = Label.new()
	_autosave_indicator.modulate.a = 0.0
	$UI.add_child(_autosave_indicator)


func _update_paint_hud(enabled: bool) -> void:
	if not _hud_paint_label:
		return
	_hud_paint_label.text = "Paint Mode: ON" if enabled else "Paint Mode: OFF"
	if enabled:
		_hud_paint_label.add_theme_color_override("font_color", Color(0.75, 0.2, 1.0, 1.0))
		_hud_paint_label.modulate.a = 1.0
	else:
		_hud_paint_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5, 1.0))
		_hud_paint_label.modulate.a = 0.45


func _flash_hud_label(lbl: Label, text: String, color: Color, tween_ref: String) -> void:
	"""Flash a HUD label with the given text/color then fade it out."""
	if not lbl:
		return
	lbl.text = text
	lbl.add_theme_color_override("font_color", color)
	var tw: Tween = get(tween_ref)
	if tw:
		tw.kill()
	tw = create_tween()
	set(tween_ref, tw)
	tw.tween_property(lbl, "modulate:a", 1.0, 0.2)
	tw.tween_interval(2.0)
	tw.tween_property(lbl, "modulate:a", 0.0, 0.6)


func _show_autosave_indicator() -> void:
	"""Flash the autosave HUD label."""
	_flash_hud_label(
		_hud_autosave_label,
		"autosave.tmp written",
		Color(0.55, 0.55, 0.55, 1.0),
		"_hud_autosave_tween"
	)


func _show_save_indicator(filename: String) -> void:
	"""Flash the save HUD label with the saved filename."""
	_flash_hud_label(
		_hud_save_label,
		"Saved: " + filename.get_file(),
		Color(0.4, 0.85, 0.4, 1.0),
		"_hud_save_tween"
	)


func _tick_autosave(delta: float) -> void:
	if not _autosave_enabled:
		return
	if not has_unsaved_changes:
		return
	if tilemap.tile_manager.is_flushing:
		return
	if is_exporting:
		return
	if input_handler and input_handler.is_loading:
		return

	_autosave_timer -= delta
	if _autosave_timer > 0.0:
		return

	_autosave_timer = AUTOSAVE_INTERVAL
	_do_autosave()


func _do_autosave() -> void:
	"""
	1. If a named save file exists, overwrite it (same as Ctrl+S).
	2. Always write the crash-recovery .tmp.
	3. Flash the indicator.
	"""
	if tilemap == null or tilemap.tiles.is_empty():
		return

	var did_something := false

	# Overwrite the named save if we have one
	if current_save_file != "":
		if LevelSaveLoad.save_level(tilemap, y_level_manager, current_save_file, material_palette):
			has_unsaved_changes = false
			did_something = true

	# Always write crash-recovery .tmp
	if LevelSaveLoad.save_level(tilemap, y_level_manager, _get_tmp_path(), material_palette):
		did_something = true
	else:
		Console.warn("[Autosave] Failed to write recovery file: ", _get_tmp_path())

	if did_something:
		var named := (" + " + current_save_file.get_file()) if current_save_file != "" else ""
		Console.info("[Autosave]", named, " autosave.tmp written")
		_show_autosave_indicator()


func _do_autosave_tmp_only() -> void:
	"""Write just the .tmp — called after explicit saves to keep recovery in sync."""
	if tilemap == null or tilemap.tiles.is_empty():
		return
	LevelSaveLoad.save_level(tilemap, y_level_manager, _get_tmp_path(), material_palette)


func _register_console_commands() -> void:
	Console.register_command("fps",
		func(_args: Array) -> void:
			var overlay := get_tree().get_first_node_in_group("fps_overlay")
			if overlay:
				overlay.visible = not overlay.visible
				Console.info("FPS counter ", "on" if overlay.visible else "off")
			else:
				var lbl := Label.new()
				lbl.add_to_group("fps_overlay")
				lbl.set_anchors_preset(Control.PRESET_TOP_RIGHT)
				lbl.position = Vector2(-120, 8)
				lbl.add_theme_font_size_override("font_size", 14)
				lbl.add_theme_color_override("font_color", Color(0.2, 1.0, 0.4, 1.0))
				var timer := Timer.new()
				timer.wait_time = 0.25
				timer.autostart = true
				timer.timeout.connect(func() -> void: lbl.text = "FPS: %d" % Engine.get_frames_per_second())
				lbl.add_child(timer)
				$UI.add_child(lbl)
				Console.info("FPS counter on"),
		"Toggle FPS counter overlay")

	Console.register_command("tile_count",
		func(_args: Array) -> void:
			if tilemap:
				Console.info("Tiles in level: ", tilemap.tiles.size())
			else:
				Console.error("No tilemap loaded"),
		"Print number of tiles in the current level")

	Console.register_command("clear_level",
		func(args: Array) -> void:
			if args.is_empty() or args[0] != "confirm":
				Console.warn("This will delete all tiles. Type \'clear_level confirm\' to proceed.")
				return
			if tilemap:
				tilemap.clear_all_tiles()
				has_unsaved_changes = true
				Console.info("Level cleared.")
			else:
				Console.error("No tilemap loaded"),
		"Clear all tiles. Usage: clear_level confirm")

	Console.register_command("reload_materials",
		func(_args: Array) -> void:
			if material_palette:
				material_palette.reload_materials()
				Console.info("Materials reloaded.")
			else:
				Console.error("No material palette found"),
		"Reload material palette from disk")

	Console.register_command("save",
		func(_args: Array) -> void:
			quick_save_level()
			Console.info("Saved to: ", current_save_file if current_save_file != "" else "(no file — opened Save As)"),
		"Quick save the current level")

	Console.register_command("load",
		func(args: Array) -> void:
			if args.is_empty():
				Console.error("Usage: load <path>")
				return
			var path := " ".join(args)
			if not FileAccess.file_exists(path):
				Console.error("File not found: ", path)
				return
			_begin_loading()
			call_deferred("_do_load_read", path),
		"Load a level by path. Usage: load <path>")

	Console.register_command("max_fps",
		func(args: Array) -> void:
			if args.is_empty():
				Console.info("Current max FPS: ", Engine.max_fps, " (0 = unlimited)")
				return
			if not args[0].is_valid_int():
				Console.error("Usage: max_fps <number>  (0 = unlimited)")
				return
			Engine.max_fps = int(args[0])
			Console.info("Max FPS set to: ", Engine.max_fps, " (0 = unlimited)" if Engine.max_fps == 0 else ""),
		"Get or set max FPS. Usage: max_fps <number>  (0 = unlimited)")

	Console.register_command("vsync",
		func(args: Array) -> void:
			if args.is_empty():
				var current := DisplayServer.window_get_vsync_mode()
				Console.info("VSync: ", "on" if current != DisplayServer.VSYNC_DISABLED else "off")
				return
			var mode: String = args[0].to_lower()
			if mode == "on":
				DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)
				Console.info("VSync enabled")
			elif mode == "off":
				DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
				Console.info("VSync disabled")
			elif mode == "adaptive":
				DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ADAPTIVE)
				Console.info("VSync set to adaptive")
			else:
				Console.error("Usage: vsync on|off|adaptive"),
		"Get or set VSync. Usage: vsync on|off|adaptive")

	Console.register_command("autosave",
		func(args: Array) -> void:
			if args.is_empty():
				Console.info("Autosave: ", "enabled" if _autosave_enabled else "disabled")
				Console.info("Interval: ", AUTOSAVE_INTERVAL, "s  |  Next in: %.0fs" % _autosave_timer)
				Console.info("Recovery file: ", _get_tmp_path())
				Console.info("Recovery exists: ", FileAccess.file_exists(_get_tmp_path()))
				return
			var cmd: String = args[0].to_lower()
			if cmd == "on":
				_autosave_enabled = true
				Console.info("Autosave enabled")
			elif cmd == "off":
				_autosave_enabled = false
				Console.info("Autosave disabled")
			elif cmd == "now":
				_do_autosave()
			else:
				Console.error("Usage: autosave [on|off|now]"),
		"Manage autosave. Usage: autosave [on|off|now]")


func _setup_block_menu() -> void:
	if not block_menu:
		return

	var stairs_mesh: ArrayMesh = ProceduralStairsGenerator.generate_stairs_mesh(4, grid_size, 0.0)

	var tile_defs: Array = [
		{
			"type": 0,
			"label": "Cube",
			"mesh_path": "res://cubes/cube_bulge.obj",
			"mesh": null
		},
		{
			"type": 1,
			"label": "Bevel",
			"mesh_path": "res://cubes/half_bevel.obj",
			"mesh": null
		},
		{
			"type": MeshGenerator.TILE_TYPE_STAIRS,
			"label": "Stairs",
			"mesh_path": "",
			"mesh": stairs_mesh,
			"preview_rotation_y": 180.0
		},
	]

	block_menu.setup(tile_defs)
	block_menu.tile_type_selected.connect(_on_block_menu_tile_selected)
	block_menu.ui_hover_changed.connect(_on_block_menu_hover_changed)

	call_deferred("_refresh_block_menu_previews")


# ============================================================================
# BLOCK MENU CALLBACKS
# ============================================================================

func _on_block_menu_tile_selected(tile_type: int) -> void:
	current_tile_type = tile_type
	selection_manager.update_state(current_y_level, current_tile_type)


func _on_block_menu_hover_changed(is_hovered: bool) -> void:
	input_handler.set_ui_hovered(is_hovered)
	if cursor_visualizer:
		if is_hovered:
			cursor_visualizer.hide()
		else:
			if not is_popup_open:
				cursor_visualizer.show()


func _refresh_block_menu_previews() -> void:
	if not block_menu or not material_palette:
		return

	var index = current_painting_material_index if current_painting_material_index >= 0 else 0

	var surface_materials: Array = [
		material_palette.get_material_for_surface(index, 0),
		material_palette.get_material_for_surface(index, 1),
		material_palette.get_material_for_surface(index, 2),
	]
	block_menu.update_preview_materials(surface_materials)


# ============================================================================
# MATERIAL SELECTION
# ============================================================================

func _on_material_selected(material_index: int):
	current_painting_material_index = material_index
	current_painting_material = material_palette.get_material_at_index(material_index)

	if current_painting_material:
		var material_data = material_palette.get_material_data_at_index(material_index)
		var material_name = material_data.get("name", "Unknown")
		Console.info("Material selected for painting: ", material_name, " (index: ", material_index, ")")
		input_handler.set_painting_material(material_index)
		_refresh_block_menu_previews()
	else:
		Console.info("Warning: Material at index ", material_index, " is null")

# ============================================================================
# MAIN LOOP
# ============================================================================

func _process(delta):
	selection_manager.process_queue()
	tilemap.tick()

	# Finish loading once all flushes are complete
	if input_handler and input_handler.is_loading and not tilemap.tile_manager.is_flushing and not is_exporting:
		_end_loading()

	var is_loading = input_handler and input_handler.is_loading
	var console_visible: bool = console_panel and console_panel.visible
	if camera:
		camera.console_open = console_visible
	if input_handler:
		input_handler.console_open = console_visible
	if camera and cursor_visualizer and not is_popup_open and not is_loading and not is_exporting and not console_visible:
		_update_cursor()
		input_handler.handle_continuous_input(delta)

	_tick_autosave(delta)


func _on_first_launch() -> void:
	var dialog: Window = FirstLaunchDialog.instantiate()
	add_child(dialog)
	dialog.popup_centered()
	_on_popup_state_changed(true)
	dialog.setup_confirmed.connect(func() -> void:
		_on_popup_state_changed(false)
		_setup_file_dialogs()
		startup_picker.visible = true
		_on_popup_state_changed(true)
		_setup_startup_picker()
	)


func _setup_escape_menu() -> void:
	escape_menu.resume_pressed.connect(func() -> void:
		_on_popup_state_changed(false)
	)
	escape_menu.save_pressed.connect(func() -> void:
		_on_popup_state_changed(false)
		show_save_dialog()
	)
	escape_menu.load_pressed.connect(func() -> void:
		if has_unsaved_changes:
			escape_menu.show_unsaved_warning("load")
		else:
			escape_menu.close()
			_on_popup_state_changed(false)
			show_load_dialog()
	)
	escape_menu.export_pressed.connect(func() -> void:
		escape_menu.close()
		_on_popup_state_changed(false)
		show_export_dialog()
	)
	escape_menu.change_data_folder_pressed.connect(func() -> void:
		escape_menu.close()
		_on_popup_state_changed(false)
		var dialog: Window = FirstLaunchDialog.instantiate()
		add_child(dialog)
		dialog.popup_centered()
		_on_popup_state_changed(true)
		dialog.setup_confirmed.connect(func() -> void:
			_on_popup_state_changed(false)
		)
	)
	escape_menu.keybinds_pressed.connect(func() -> void:
		pass  # TODO: open keybinds panel
	)
	escape_menu.quit_confirmed.connect(func() -> void:
		if has_unsaved_changes:
			escape_menu.show_unsaved_warning("quit")
		else:
			_shutdown()
	)
	escape_menu.unsaved_confirmed_load.connect(func() -> void:
		escape_menu.close()
		_on_popup_state_changed(false)
		show_load_dialog()
	)
	escape_menu.unsaved_confirmed_quit.connect(_shutdown)


func _shutdown() -> void:
	"""Graceful shutdown — delete .tmp (clean exit), join threads, quit."""
	Console.info("[SHUTDOWN] _shutdown() called")
	_delete_tmp()
	if _export_thread and _export_thread.is_alive():
		Console.info("[SHUTDOWN] Waiting for export thread to finish...")
		_export_thread.wait_to_finish()
		Console.info("[SHUTDOWN] Export thread joined OK")
	if tilemap:
		Console.info("[SHUTDOWN] Calling tilemap.cleanup()...")
		tilemap.cleanup()
		Console.info("[SHUTDOWN] tilemap.cleanup() returned — calling get_tree().quit()")
	get_tree().quit()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		Console.info("[SHUTDOWN] WM_CLOSE_REQUEST received")
		if has_unsaved_changes:
			escape_menu.open()
			_on_popup_state_changed(true)
			escape_menu.show_unsaved_warning("quit")
		else:
			_shutdown()

# ============================================================================
# INPUT HANDLING
# ============================================================================

func _input(event):
	if is_popup_open:
		return

	if console_panel and console_panel.visible:
		if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
			get_viewport().set_input_as_handled()
			console_panel.hide_console()
		return

	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		if not escape_menu.visible:
			escape_menu.open()
			_on_popup_state_changed(true)
			get_viewport().set_input_as_handled()
			return

	var result = input_handler.process_input(event, current_mode, current_tile_type, current_y_level)
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_F5:
			debug_corner_culling()
	if result:
		if result.has("action") and result["action"] == "toggle_mode":
			_toggle_mode()
		if result.has("tile_type"):
			current_tile_type = result["tile_type"]
		if result.has("y_level"):
			current_y_level = result["y_level"]

	selection_manager.update_state(current_y_level, current_tile_type)

	if event is InputEventMouseButton and not input_handler.is_ui_hovered:
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			input_handler.handle_mouse_wheel(1.0)
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			input_handler.handle_mouse_wheel(-1.0)

	if Input.is_action_just_pressed("reset_fov"):
		camera.reset_fov()

	if Input.is_action_just_pressed("export"):
		show_export_dialog()
	if Input.is_action_just_pressed("save_as"):
		show_save_dialog()
	if Input.is_action_just_pressed("load"):
		if has_unsaved_changes:
			escape_menu.open()
			_on_popup_state_changed(true)
			escape_menu.show_unsaved_warning("load")
		else:
			show_load_dialog()
	if Input.is_action_just_pressed("quick_save"):
		quick_save_level()

# ============================================================================
# CURSOR UPDATE
# ============================================================================

func _update_cursor():
	var viewport = get_viewport()
	if not viewport:
		return

	var mouse_pos = viewport.get_mouse_position()
	var from = camera.project_ray_origin(mouse_pos)
	var to = from + camera.project_ray_normal(mouse_pos) * 1000

	var offset = y_level_manager.get_offset(current_y_level)
	var y_world = current_y_level * grid_size
	var placement_plane = Plane(Vector3.UP, y_world)
	var intersection = placement_plane.intersects_ray(from, to - from)

	if intersection:
		var adjusted_intersection = intersection - Vector3(offset.x, 0, offset.y)
		var grid_pos = Vector3i(
			floori(adjusted_intersection.x / grid_size),
			current_y_level,
			floori(adjusted_intersection.z / grid_size)
		)

		if abs(grid_pos.x) > grid_range or abs(grid_pos.z) > grid_range:
			return

		if selection_manager.is_selecting and current_mode == EditorMode.SELECT:
			selection_manager.update_selection(mouse_pos)

		var tile_exists = tilemap.has_tile(grid_pos)

		cursor_visualizer.current_tile_type = current_tile_type
		cursor_visualizer.current_step_count = current_stair_steps
		cursor_visualizer.current_rotation = 180.0 if current_tile_type == 5 else 0.0

		cursor_visualizer.update_cursor_with_offset(camera, current_y_level, tile_exists, offset)

# ============================================================================
# MODE MANAGEMENT
# ============================================================================

func _toggle_mode():
	if current_mode == EditorMode.EDIT:
		current_mode = EditorMode.SELECT
		Console.info("Mode: SELECT (Drag to select, F to fill, Delete/X to clear, R to rotate)")
	else:
		current_mode = EditorMode.EDIT
		selection_manager.clear_selection()
		Console.info("Mode: EDIT")


func _on_paint_mode_changed(enabled: bool) -> void:
	cursor_visualizer.paint_mode = enabled
	selection_manager.set_paint_mode(enabled)
	_update_paint_hud(enabled)


func _on_window_focus_entered():
	window_has_focus = true


func _on_window_focus_exited():
	window_has_focus = false
	if input_handler:
		input_handler.mouse_pressed = false


func _on_material_palette_hover_changed(is_hovered: bool):
	input_handler.set_ui_hovered(is_hovered)

	if cursor_visualizer:
		if is_hovered:
			cursor_visualizer.hide()
		else:
			if not is_popup_open:
				cursor_visualizer.show()


func _on_popup_state_changed(is_open: bool) -> void:
	_popup_open_count += 1 if is_open else -1
	_popup_open_count = maxi(_popup_open_count, 0)
	is_popup_open = _popup_open_count > 0

	if is_popup_open:
		camera.set_process(false)
		if cursor_visualizer:
			cursor_visualizer.hide()
	else:
		camera.set_process(true)
		if cursor_visualizer:
			cursor_visualizer.show()


# ============================================================================
# Y-LEVEL OFFSET (for TileMap3D)
# ============================================================================

func get_y_level_offset(y_level: int) -> Vector2:
	return y_level_manager.get_offset(y_level)


func set_y_level_offset(y_level: int, x_offset: float, z_offset: float):
	y_level_manager.set_offset(y_level, x_offset, z_offset)


func clear_y_level_offset(y_level: int):
	y_level_manager.clear_offset(y_level)


# ============================================================================
# ROTATION FUNCTIONS
# ============================================================================

func rotate_selection_cw():
	selection_manager.rotate_selected_tiles(rotation_increment)

func rotate_selection_ccw():
	selection_manager.rotate_selected_tiles(-rotation_increment)


# ============================================================================
# SAVE/LOAD FUNCTIONS
# ============================================================================

func quick_save_level():
	"""Quick save — overwrite current file, or open Save As if none exists."""
	if current_save_file != "":
		if LevelSaveLoad.save_level(tilemap, y_level_manager, current_save_file, material_palette):
			has_unsaved_changes = false
			_autosave_timer = AUTOSAVE_INTERVAL
			# Keep the recovery .tmp in sync
			_do_autosave_tmp_only()
			_show_save_indicator(current_save_file)
			Console.info("\n=== QUICK SAVE ===")
			Console.info("Saved to: ", ProjectSettings.globalize_path(current_save_file))
			Console.info("==================\n")
	else:
		Console.info("No file loaded - opening Save As dialog...")
		show_save_dialog()


func save_level_with_name(level_name: String) -> void:
	var filepath: String = LevelSaveLoad.get_save_filepath(level_name)
	if LevelSaveLoad.save_level(tilemap, y_level_manager, filepath, material_palette):
		current_save_file = filepath
		has_unsaved_changes = false
		_autosave_timer = AUTOSAVE_INTERVAL
		Console.info("\n=== LEVEL SAVED ===")
		Console.info("Saved to: ", filepath)
		Console.info("===================\n")


func load_last_level():
	var levels = LevelSaveLoad.list_saved_levels()
	if levels.is_empty():
		Console.info("No saved levels found")
		return

	levels.sort()
	var last_level = levels[-1]
	var filepath = AppConfig.saves_dir + last_level

	_begin_loading()
	if LevelSaveLoad.load_level(tilemap, y_level_manager, filepath, material_palette, _make_load_progress_callback()):
		Console.info("\n=== LEVEL LOADED ===")
		Console.info("Loaded from: ", filepath)
		Console.info("====================\n")
		y_level_manager.change_y_level(current_y_level)
	else:
		_end_loading()


func load_level_by_name(filename: String):
	var filepath = AppConfig.saves_dir + filename
	_begin_loading()
	call_deferred("_do_load_read", filepath)


func list_saved_levels():
	var levels = LevelSaveLoad.list_saved_levels()
	Console.info("\n=== SAVED LEVELS ===")
	if levels.is_empty():
		Console.info("No saved levels found")
	else:
		for level in levels:
			Console.info("  - ", level)
	Console.info("====================\n")

# ============================================================================
# FILE DIALOG HANDLERS
# ============================================================================

@onready var export_dialog: FileDialog = $UI/Export
@onready var save_dialog: FileDialog = $UI/Save
@onready var load_dialog: FileDialog = $UI/Load

func _on_export_confirmed(is_chunked: bool, path: String):
	if _export_thread and _export_thread.is_alive():
		Console.info("Export already in progress, please wait.")
		return

	Console.info("\n=== EXPORTING LEVEL ===")
	Console.info("Format: ", "Chunked" if is_chunked else "Single")
	Console.info("Path: ", path)

	_show_export_overlay("Exporting… please wait")
	is_exporting = true
	input_handler.is_loading = true
	camera.set_process(false)

	var top_plane_snapshot := tilemap.capture_top_plane_snapshot()
	var enclosed_snapshot := tilemap.capture_enclosed_snapshot()
	var neighbors_snapshot := tilemap.capture_neighbors_snapshot()

	tilemap.glb_exporter.progress_callback = func(done: int, total: int) -> void:
		call_deferred("_update_export_progress", done, total)

	_export_thread = Thread.new()
	if is_chunked:
		var save_name := path.get_basename().get_file()
		if save_name.is_empty():
			save_name = "level_chunks"
		_export_thread.start(_thread_export_chunked.bind(save_name, top_plane_snapshot, enclosed_snapshot, neighbors_snapshot))
	else:
		if not path.ends_with(".glb") and not path.ends_with(".gltf"):
			path += ".glb"
		_export_thread.start(_thread_export_single.bind(path, top_plane_snapshot, enclosed_snapshot, neighbors_snapshot))


func _thread_export_single(filepath: String, top_plane_snapshot: Array, enclosed_snapshot: Dictionary = {}, neighbors_snapshot: Dictionary = {}) -> void:
	var mesh := tilemap.glb_exporter.build_export_mesh(top_plane_snapshot, enclosed_snapshot, neighbors_snapshot)
	tilemap.glb_exporter.progress_callback = Callable()
	call_deferred("_finish_export_single", mesh, filepath)


func _thread_export_chunked(save_name: String, top_plane_snapshot: Array, enclosed_snapshot: Dictionary = {}, neighbors_snapshot: Dictionary = {}) -> void:
	var chunk_data := tilemap.glb_exporter.build_chunk_meshes(save_name, top_plane_snapshot, GlbExporter.CHUNK_SIZE, enclosed_snapshot, neighbors_snapshot)
	tilemap.glb_exporter.progress_callback = Callable()
	call_deferred("_finish_export_chunked", chunk_data)


func _finish_export_single(mesh: ArrayMesh, filepath: String) -> void:
	_export_thread.wait_to_finish()
	is_exporting = false
	input_handler.is_loading = false
	camera.set_process(true)
	var ok := tilemap.glb_exporter.save_single(mesh, filepath)
	if ok:
		var real_path := ProjectSettings.globalize_path(filepath)
		Console.info("✓ GLB exported: ", real_path)
		_show_export_overlay("✓ Export complete!\n" + real_path, true)
	else:
		Console.error("GLB export failed — see above for details.")
		_hide_export_overlay()
	Console.info("======================\n")


func _finish_export_chunked(chunk_data: Dictionary) -> void:
	_export_thread.wait_to_finish()
	is_exporting = false
	input_handler.is_loading = false
	camera.set_process(true)
	if chunk_data.is_empty():
		Console.error("Chunked export: mesh build returned no data")
		_hide_export_overlay()
		return
	_show_export_overlay("Saving chunks…")
	tilemap.glb_exporter.save_chunks(chunk_data)
	var real_path := ProjectSettings.globalize_path(chunk_data["export_dir"])
	Console.info("✓ Chunked GLB export complete: ", real_path)
	_show_export_overlay("✓ Export complete!\n" + real_path, true)
	Console.info("======================\n")


func _update_export_progress(done: int, total: int) -> void:
	if not _export_bar_fill or not _export_pct_label:
		return
	var pct = float(done) / float(total) if total > 0 else 0.0
	_export_bar_fill.size.x = _export_bar.size.x * pct
	_export_pct_label.text = "%d%%" % int(pct * 100)
	if _export_label:
		_export_label.text = "Exporting mesh…"


func _show_export_overlay(message: String, auto_hide: bool = false) -> void:
	if not _export_overlay:
		_export_overlay = CanvasLayer.new()
		_export_overlay.layer = 128

		var bg = ColorRect.new()
		bg.color = Color(0, 0, 0, 0.55)
		bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_export_overlay.add_child(bg)

		var vbox = VBoxContainer.new()
		vbox.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
		vbox.custom_minimum_size = Vector2(500, 120)
		vbox.offset_left = -250
		vbox.offset_top = -60
		vbox.offset_right = 250
		vbox.offset_bottom = 60
		vbox.alignment = BoxContainer.ALIGNMENT_CENTER
		_export_overlay.add_child(vbox)

		_export_label = Label.new()
		_export_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_export_label.add_theme_font_size_override("font_size", 22)
		vbox.add_child(_export_label)

		_export_bar = ColorRect.new()
		_export_bar.color = Color(0.2, 0.2, 0.2, 1.0)
		_export_bar.custom_minimum_size = Vector2(500, 24)
		vbox.add_child(_export_bar)

		_export_bar_fill = ColorRect.new()
		_export_bar_fill.color = Color(0.2, 0.8, 0.4, 1.0)
		_export_bar_fill.size = Vector2(0, 24)
		_export_bar_fill.position = Vector2(0, 0)
		_export_bar.add_child(_export_bar_fill)

		_export_pct_label = Label.new()
		_export_pct_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_export_pct_label.add_theme_font_size_override("font_size", 16)
		_export_pct_label.text = "0%"
		vbox.add_child(_export_pct_label)

		add_child(_export_overlay)

	if _export_bar_fill:
		_export_bar_fill.size.x = 0
	if _export_pct_label:
		_export_pct_label.text = "0%"

	_export_label.text = message
	_export_overlay.visible = true

	if auto_hide:
		await get_tree().create_timer(2.5).timeout
		_hide_export_overlay()


func _hide_export_overlay() -> void:
	if _export_overlay:
		_export_overlay.visible = false


# ── Loading helpers ──────────────────────────────────────────────────────────

func _begin_loading() -> void:
	if input_handler:
		input_handler.is_loading = true
	if camera:
		camera.set_process(false)
	_show_export_overlay("Loading level…")


func _end_loading() -> void:
	if input_handler:
		input_handler.is_loading = false
	if camera:
		camera.set_process(true)
	_hide_export_overlay()


func _make_load_progress_callback() -> Callable:
	return func(done: int, total: int) -> void:
		call_deferred("_update_load_progress", done, total)


func _update_load_progress(done: int, total: int) -> void:
	if not _export_bar_fill or not _export_pct_label:
		return
	var pct := float(done) / float(total) if total > 0 else 0.0
	_export_bar_fill.size.x = _export_bar.size.x * pct
	_export_pct_label.text = "%d%%" % int(pct * 100)
	if _export_label:
		_export_label.text = "Loading level…"


func _on_save_confirmed(path: String):
	var save_path := path if path.ends_with(".level") else path + ".level"
	if LevelSaveLoad.save_level(tilemap, y_level_manager, save_path, material_palette):
		current_save_file = save_path
		has_unsaved_changes = false
		_autosave_timer = AUTOSAVE_INTERVAL
		# Keep the recovery .tmp in sync with the new named file
		_do_autosave_tmp_only()
		_show_save_indicator(save_path)
		AppConfig.add_recent_file(ProjectSettings.globalize_path(save_path))
		Console.info("\n=== LEVEL SAVED ===")
		Console.info("Saved to: ", ProjectSettings.globalize_path(save_path))
		Console.info("===================\n")


func _on_load_confirmed(path: String):
	if _loading_from_startup_picker:
		_loading_from_startup_picker = false
		startup_picker.visible = false
		_on_popup_state_changed(false)
	# Loading a real file means the .tmp is no longer needed for recovery
	_delete_tmp()
	_begin_loading()
	call_deferred("_do_load_read", path)


func _do_load_read(path: String):
	if tilemap.tile_manager.is_flushing:
		call_deferred("_do_load_read", path)
		return

	var file = FileAccess.open(path, FileAccess.READ)
	if file == null:
		_end_loading()
		Console.error("Failed to open file: ", path)
		return
	var json_string = file.get_as_text()
	file.close()
	var json = JSON.new()
	if json.parse(json_string) != OK:
		_end_loading()
		Console.error("Failed to parse JSON: ", json.get_error_message())
		return
	call_deferred("_do_load_apply", path, json.data)


func _do_load_apply(path: String, save_data: Dictionary):
	if LevelSaveLoad.load_level_from_data(tilemap, y_level_manager, path, save_data, material_palette, _make_load_progress_callback()):
		# Don't set the .tmp as the current save file — recovered work needs a proper name
		if path != _get_tmp_path():
			current_save_file = path
			AppConfig.add_recent_file(ProjectSettings.globalize_path(path))
		else:
			has_unsaved_changes = true
			Console.info("[Recovery] Level recovered from autosave. Use Save As (Ctrl+Shift+S) to give it a permanent name.")

		Console.info("\n=== LEVEL LOADED ===")
		Console.info("Loaded from: ", ProjectSettings.globalize_path(path))
		Console.info("====================\n")
		if undo_redo:
			undo_redo.clear()
		y_level_manager.change_y_level(current_y_level)
		_autosave_timer = AUTOSAVE_INTERVAL
		_warmup_palette_materials()
	else:
		_end_loading()
		Console.error("Failed to load level from: ", path)
		Console.info("ERROR: Load failed!")


func _warmup_palette_materials() -> void:
	if not material_palette or not material_palette.has_method("get_material_for_surface"):
		return

	const WARMUP_POS := Vector3(0.0, -99999.0, 0.0)
	var warmup_root := Node3D.new()
	warmup_root.position = WARMUP_POS
	add_child(warmup_root)

	var warmup_mesh := ArrayMesh.new()
	var sa := []
	sa.resize(Mesh.ARRAY_MAX)
	sa[Mesh.ARRAY_VERTEX]  = PackedVector3Array([Vector3(0,0,0), Vector3(0.001,0,0), Vector3(0,0.001,0)])
	sa[Mesh.ARRAY_NORMAL]  = PackedVector3Array([Vector3.UP, Vector3.UP, Vector3.UP])
	sa[Mesh.ARRAY_TEX_UV]  = PackedVector2Array([Vector2.ZERO, Vector2.ZERO, Vector2.ZERO])
	sa[Mesh.ARRAY_INDEX]   = PackedInt32Array([0, 1, 2])
	warmup_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, sa)

	var mat_count: int = 0
	var seen: Dictionary = {}
	for i in range(256):
		var got_any := false
		for surf in range(3):
			var mat: StandardMaterial3D = material_palette.get_material_for_surface(i, surf)
			if mat == null:
				continue
			got_any = true
			var mat_id := mat.get_instance_id()
			if mat_id in seen:
				continue
			seen[mat_id] = true
			var mi := MeshInstance3D.new()
			mi.mesh = warmup_mesh
			mi.material_override = mat
			warmup_root.add_child(mi)
			mat_count += 1
		if not got_any and i > 0:
			break

	if mat_count == 0:
		warmup_root.queue_free()
		return

	Console.info("Warming up ", mat_count, " palette material(s)…")
	var timer := Timer.new()
	timer.wait_time = 0.05
	timer.one_shot = true
	timer.autostart = true
	warmup_root.add_child(timer)
	timer.timeout.connect(warmup_root.queue_free)


# ============================================================================
# FILE DIALOGS
# ============================================================================

func _setup_file_dialogs() -> void:
	export_dialog.filters = PackedStringArray(["*.glb ; GLB Files", "*.gltf ; GLTF Files"])
	save_dialog.filters   = PackedStringArray(["*.level ; Level Files"])
	load_dialog.filters   = PackedStringArray(["*.level ; Level Files"])

	if DirAccess.dir_exists_absolute(AppConfig.exports_dir):
		export_dialog.root_subfolder = AppConfig.exports_dir
	if DirAccess.dir_exists_absolute(AppConfig.saves_dir):
		save_dialog.root_subfolder = AppConfig.saves_dir
		load_dialog.root_subfolder = AppConfig.saves_dir


func show_export_dialog() -> void:
	if has_unsaved_changes:
		quick_save_level()
	export_dialog.popup_centered_ratio(0.6)


func show_save_dialog() -> void:
	save_dialog.popup_centered_ratio(0.6)


func show_load_dialog() -> void:
	load_dialog.popup_centered_ratio(0.6)


func debug_corner_culling():
	if tilemap:
		tilemap.print_corner_debug()
	else:
		Console.info("TileMap not initialized")
