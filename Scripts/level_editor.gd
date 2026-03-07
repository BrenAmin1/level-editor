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

	# Ensure save directory exists (no-op, AppConfig handles this)
	LevelSaveLoad.ensure_save_directory()
	
	# Connect FileDialog signals
	export_dialog.export_confirmed.connect(_on_export_confirmed)
	save_dialog.save_confirmed.connect(_on_save_confirmed)
	load_dialog.load_confirmed.connect(_on_load_confirmed)

	# Set file dialog directories and filters from AppConfig.
	# Done here in code rather than the scene so the directories are guaranteed
	# to exist (AppConfig creates them on startup) before we set root_subfolder.
	_setup_file_dialogs()
	_show_startup_picker()
	console_panel.setup(camera)
	_register_console_commands()
	
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

	# Setup block menu
	_setup_block_menu()
	_setup_escape_menu()
	
	Console.info("Mode: EDIT (Press TAB to toggle)")
	Console.info("\nSave/Load Controls:")
	Console.info("  Ctrl, S - Quick save (saves to current file, or quicksave.json if none)")
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


func _show_startup_picker() -> void:
	"""Show startup picker unless we are resuming from first launch dialog."""
	if AppConfig.is_first_launch:
		# First launch dialog already shown — connect to show picker after it closes
		var fld_node: Window = get_node_or_null("%FirstLaunchDialog")
		if fld_node:
			fld_node.setup_confirmed.connect(_show_startup_picker, CONNECT_ONE_SHOT)
			return
	startup_picker.visible = true
	_on_popup_state_changed(true)
	_setup_startup_picker()


func _setup_startup_picker() -> void:
	startup_picker.new_level_pressed.connect(func() -> void:
		startup_picker.visible = false
		_on_popup_state_changed(false)
	)
	startup_picker.open_pressed.connect(func() -> void:
		# Keep startup_picker visible — dismissed in _on_load_confirmed once a file is picked.
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


func _register_console_commands() -> void:
	"""Register editor-specific console commands that need level_editor references."""
	Console.register_command("fps",
		func(_args: Array) -> void:
			var overlay := get_tree().get_first_node_in_group("fps_overlay")
			if overlay:
				overlay.visible = not overlay.visible
				Console.info("FPS counter ", "on" if overlay.visible else "off")
			else:
				# Create a simple FPS label and add it to UI
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
			Console.info("Saved to: ", current_save_file if current_save_file != "" else "quicksave.level"),
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
			var mode = args[0].to_lower()
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


func _setup_block_menu() -> void:
	if not block_menu:
		return

	# Stairs are procedural so we generate the mesh directly.
	# OBJ types pass their path so BlockMenu loads + reclassifies them
	# by normal direction, matching the material_maker_popup approach.
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

	# Defer one frame so material_palette._ready() has finished adding its
	# default materials before we try to read surface resources from it.
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

	# Fall back to index 0 (first default material) if nothing explicitly selected yet
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
	"""Handle material selection from the material palette"""
	current_painting_material_index = material_index
	current_painting_material = material_palette.get_material_at_index(material_index)
	
	if current_painting_material:
		var material_data = material_palette.get_material_data_at_index(material_index)
		var material_name = material_data.get("name", "Unknown")
		Console.info("Material selected for painting: ", material_name, " (index: ", material_index, ")")
		
		# Pass material index to input handler
		input_handler.set_painting_material(material_index)

		# Update block menu previews to reflect the new material
		_refresh_block_menu_previews()
	else:
		Console.info("Warning: Material at index ", material_index, " is null")

# ============================================================================
# MAIN LOOP
# ============================================================================

func _process(_delta):
	selection_manager.process_queue()
	tilemap.tick()

	# Finish loading once all flushes are complete
	if input_handler and input_handler.is_loading and not tilemap.tile_manager.is_flushing and not is_exporting:
		_end_loading()

	# Don't update cursor when popup is open, level is loading, or console is open
	var is_loading = input_handler and input_handler.is_loading
	var console_visible: bool = console_panel and console_panel.visible
	if camera:
		camera.console_open = console_visible
	if input_handler:
		input_handler.console_open = console_visible
	if camera and cursor_visualizer and not is_popup_open and not is_loading and not is_exporting and not console_visible:
		_update_cursor()
		input_handler.handle_continuous_input(_delta)


func _on_first_launch() -> void:
	"""Show the first-launch data directory setup dialog, then startup picker."""
	var dialog: Window = FirstLaunchDialog.instantiate()
	add_child(dialog)
	dialog.popup_centered()
	_on_popup_state_changed(true)
	dialog.setup_confirmed.connect(func() -> void:
		_on_popup_state_changed(false)
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
	"""Graceful shutdown — joins threads then quits."""
	Console.info("[SHUTDOWN] _shutdown() called")
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
	# Block all input when popup is open (except closing the popup itself)
	if is_popup_open:
		return

	# Console open — only allow escape to close it, nothing else
	if console_panel and console_panel.visible:
		if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
			get_viewport().set_input_as_handled()
			console_panel.hide_console()
		return

	# Open escape menu — closing is handled inside escape_menu._input
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

	# Update selection manager state
	selection_manager.update_state(current_y_level, current_tile_type)

	# Handle mouse wheel for FOV
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			input_handler.handle_mouse_wheel(1.0)
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			input_handler.handle_mouse_wheel(-1.0)

	# Reset FOV
	if Input.is_action_just_pressed("reset_fov"):
		camera.reset_fov()
	
	# File operations with dialogs
	if Input.is_action_just_pressed("export"):
		show_export_dialog()
	if Input.is_action_just_pressed("save_as"):  # Ctrl+Shift+S
		show_save_dialog()
	if Input.is_action_just_pressed("load"):  # Ctrl+L
		if has_unsaved_changes:
			escape_menu.open()
			_on_popup_state_changed(true)
			escape_menu.show_unsaved_warning("load")
		else:
			show_load_dialog()
	if Input.is_action_just_pressed("quick_save"):  # Ctrl+S
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
		
		# Update selection if selecting
		if selection_manager.is_selecting and current_mode == EditorMode.SELECT:
			selection_manager.update_selection(mouse_pos)
		
		var tile_exists = tilemap.has_tile(grid_pos)
		
		# Keep cursor visualizer in sync with current editor state
		cursor_visualizer.current_tile_type = current_tile_type
		cursor_visualizer.current_step_count = current_stair_steps
		# Show stairs at their default placement rotation so the preview matches what gets placed
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


func _on_window_focus_entered():
	window_has_focus = true


func _on_window_focus_exited():
	window_has_focus = false
	# Release mouse press state when window loses focus
	if input_handler:
		input_handler.mouse_pressed = false


func _on_material_palette_hover_changed(is_hovered: bool):
	"""Handle material palette hover state"""
	input_handler.set_ui_hovered(is_hovered)
	
	if cursor_visualizer:
		if is_hovered:
			cursor_visualizer.hide()
		else:
			if not is_popup_open:
				cursor_visualizer.show()


func _on_popup_state_changed(is_open: bool) -> void:
	"""Handle popup state changes - disable camera input when any popup is open."""
	_popup_open_count += 1 if is_open else -1
	_popup_open_count = maxi(_popup_open_count, 0)  # Guard against underflow
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
# SAVE/LOAD FUNCTIONS (called by InputHandler)
# ============================================================================

func quick_save_level():
	"""Quick save - overwrites the current file, or opens save dialog if no file is loaded"""
	
	if current_save_file != "":
		var filepath = current_save_file
		
		if LevelSaveLoad.save_level(tilemap, y_level_manager, filepath, material_palette):
			has_unsaved_changes = false
			Console.info("\n=== QUICK SAVE ===")
			var real_path = ProjectSettings.globalize_path(filepath)
			Console.info("Saved to: ", real_path)
			Console.info("==================\n")
	else:
		Console.info("No file loaded - opening Save As dialog...")
		show_save_dialog()


func save_level_with_name(level_name: String) -> void:
	var filepath: String = LevelSaveLoad.get_save_filepath(level_name)
	if LevelSaveLoad.save_level(tilemap, y_level_manager, filepath, material_palette):
		current_save_file = filepath
		has_unsaved_changes = false
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
	var filepath = "user://saved_levels/" + last_level
	
	_begin_loading()
	if LevelSaveLoad.load_level(tilemap, y_level_manager, filepath, material_palette, _make_load_progress_callback()):
		Console.info("\n=== LEVEL LOADED ===")
		Console.info("Loaded from: ", filepath)
		Console.info("====================\n")
		y_level_manager.change_y_level(current_y_level)
	else:
		_end_loading()


func load_level_by_name(filename: String):
	var filepath = "user://saved_levels/" + filename
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
	"""Handle export confirmation — kicks off background thread."""
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
	"""Called on main thread via call_deferred during mesh build"""
	if not _export_bar_fill or not _export_pct_label:
		return
	var pct = float(done) / float(total) if total > 0 else 0.0
	_export_bar_fill.size.x = _export_bar.size.x * pct
	var pct_int = int(pct * 100)
	_export_pct_label.text = "%d%%" % pct_int
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
	"""Block input and show the loading overlay."""
	if input_handler:
		input_handler.is_loading = true
	if camera:
		camera.set_process(false)
	_show_export_overlay("Loading level…")


func _end_loading() -> void:
	"""Unblock input and hide the loading overlay."""
	if input_handler:
		input_handler.is_loading = false
	if camera:
		camera.set_process(true)
	_hide_export_overlay()


func _make_load_progress_callback() -> Callable:
	"""Return a progress callback that updates the export overlay bar."""
	return func(done: int, total: int) -> void:
		call_deferred("_update_load_progress", done, total)


func _update_load_progress(done: int, total: int) -> void:
	"""Called on main thread each frame during the loading flush."""
	if not _export_bar_fill or not _export_pct_label:
		return
	var pct := float(done) / float(total) if total > 0 else 0.0
	_export_bar_fill.size.x = _export_bar.size.x * pct
	_export_pct_label.text = "%d%%" % int(pct * 100)
	if _export_label:
		_export_label.text = "Loading level…"


func _on_save_confirmed(path: String):
	"""Handle save confirmation from save dialog"""
	if LevelSaveLoad.save_level(tilemap, y_level_manager, path, material_palette):
		current_save_file = path
		has_unsaved_changes = false
		AppConfig.add_recent_file(ProjectSettings.globalize_path(path))
		Console.info("\n=== LEVEL SAVED ===")
		var real_path = ProjectSettings.globalize_path(path)
		Console.info("Saved to: ", real_path)
		Console.info("===================\n")


func _on_load_confirmed(path: String):
	"""Handle load confirmation from load dialog"""
	if _loading_from_startup_picker:
		_loading_from_startup_picker = false
		startup_picker.visible = false
		_on_popup_state_changed(false)
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
		current_save_file = path
		AppConfig.add_recent_file(ProjectSettings.globalize_path(path))
		Console.info("\n=== LEVEL LOADED ===")
		var real_path = ProjectSettings.globalize_path(path)
		Console.info("Loaded from: ", real_path)
		Console.info("====================\n")
		if undo_redo:
			undo_redo.clear()
		y_level_manager.change_y_level(current_y_level)
	else:
		_end_loading()
		Console.error("Failed to load level from: ", path)
		Console.info("ERROR: Load failed!")


# ============================================================================
# FUNCTIONS TO SHOW FILE DIALOGS (call these from UI buttons)
# ============================================================================

func _setup_file_dialogs() -> void:
	"""Configure file dialog paths and filters from AppConfig."""
	export_dialog.root_subfolder = AppConfig.exports_dir
	export_dialog.filters = PackedStringArray(["*.glb ; GLB Files", "*.gltf ; GLTF Files"])

	save_dialog.root_subfolder = AppConfig.saves_dir
	save_dialog.filters = PackedStringArray(["*.level ; Level Files"])

	load_dialog.root_subfolder = AppConfig.saves_dir
	load_dialog.filters = PackedStringArray(["*.level ; Level Files"])


func show_export_dialog() -> void:
	"""Show the export file dialog. Forces a save first so the export matches the saved level."""
	if has_unsaved_changes:
		quick_save_level()
	export_dialog.popup_centered_ratio(0.6)


func show_save_dialog() -> void:
	"""Show the save file dialog"""
	save_dialog.popup_centered_ratio(0.6)


func show_load_dialog() -> void:
	"""Show the load file dialog"""
	load_dialog.popup_centered_ratio(0.6)


func debug_corner_culling():
	"""Print corner culling debug info - call this after placing tiles"""
	if tilemap:
		tilemap.print_corner_debug()
	else:
		Console.info("TileMap not initialized")
