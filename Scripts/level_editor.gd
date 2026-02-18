extends Node3D

# ============================================================================
# COMPONENTS
# ============================================================================
@onready var camera: CameraController = $Camera3D
@onready var grid_visualizer: GridVisualizer = $GridVisualizer
@onready var cursor_visualizer: CursorVisualizer = $CursorVisualizer
@onready var material_palette: FoldableContainer = $UI/MaterialPalette  # Note: Your typo "Pallete"
@onready var right_side_menu: VBoxContainer = $UI/RightSideMenu

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
var window_has_focus: bool = true
var is_popup_open: bool = false  # NEW: Track if material popup is open
var current_painting_material: StandardMaterial3D = null
var current_painting_material_index: int = -1
var current_stair_steps: int = 4  # NEW: Number of steps for procedural stairs (min 2, max 16)

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

func _ready():
	# Ensure save directory exists
	LevelSaveLoad.ensure_save_directory()
	
	# Connect FileDialog signals
	export_dialog.export_confirmed.connect(_on_export_confirmed)
	save_dialog.save_confirmed.connect(_on_save_confirmed)
	load_dialog.load_confirmed.connect(_on_load_confirmed)
	
	# Initialize TileMap3D
	tilemap = TileMap3D.new(grid_size)
	tilemap.set_parent(self)
	tilemap.set_offset_provider(Callable(self, "get_y_level_offset"))
	tilemap.set_material_palette_reference(material_palette)
	
	# Load custom mesh
	tilemap.load_obj_for_tile_type(0, "res://cubes/cube_bulge.obj")
	tilemap.set_custom_material(0, 0, GRASS)
	tilemap.set_custom_material(0, 1, DIRT)
	tilemap.set_custom_material(0, 2, DIRT)
	tilemap.load_obj_for_tile_type(1, "res://cubes/half_bevel.obj")
	tilemap.set_custom_material(1, 0, GRASS)
	tilemap.set_custom_material(1, 1, DIRT)
	tilemap.set_custom_material(1, 2, DIRT)
	
	var surfaces = tilemap.get_surface_count(3)
	print("Loaded ", surfaces, " surfaces")
	for i in range(surfaces):
		var arrays = tilemap.custom_meshes[3].surface_get_arrays(i)
		var indices = arrays[Mesh.ARRAY_INDEX]
		print("  Surface ", i, ": ", indices.size() / 3, " triangles")
	
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
	input_handler.set_undo_redo(undo_redo)
	selection_manager.set_undo_redo(undo_redo)
	
	get_window().focus_entered.connect(_on_window_focus_entered)
	get_window().focus_exited.connect(_on_window_focus_exited)
	
	# Connect material palette hover signal
	if material_palette:
		material_palette.ui_hover_changed.connect(_on_material_palette_hover_changed)
		material_palette.popup_state_changed.connect(_on_popup_state_changed)
		material_palette.material_selected.connect(_on_material_selected)
	if right_side_menu:
		var x_spin = right_side_menu.get_node("OffsetFold/PanelContainer/OffsetVContain/XSpin")
		var z_spin = right_side_menu.get_node("OffsetFold/PanelContainer/OffsetVContain/ZSpin")
		input_handler.register_focus_control(x_spin)
		input_handler.register_focus_control(z_spin)
	
	print("Mode: EDIT (Press TAB to toggle)")
	print("\nSave/Load Controls:")
	print("  Ctrl+S - Quick save (saves to current file, or quicksave.json if none)")
	print("  Ctrl+Shift+S - Save as... (opens dialog, becomes new quick save target)")
	print("  Ctrl+L - Load level (opens dialog, becomes new quick save target)")
	print("  Ctrl+E - Export mesh (opens dialog with format options)")
	print("\nEdit Controls:")
	print("  Ctrl+Z - Undo")
	print("  Ctrl+Y / Ctrl+Shift+Z - Redo")
	print("\nSelect Mode Controls (TAB to enter):")
	print("  Ctrl+C - Copy selection")
	print("  Ctrl+V - Paste at cursor")
	print("\nPaint Controls:")
	print("  P - Toggle paint mode (change materials without replacing tiles)")

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
		print("Material selected for painting: ", material_name, " (index: ", material_index, ")")
		
		# Pass material index to input handler
		input_handler.set_painting_material(material_index)
	else:
		print("Warning: Material at index ", material_index, " is null")

# ============================================================================
# MAIN LOOP
# ============================================================================

# In the _process function, add a check for is_popup_open
func _process(_delta):
	selection_manager.process_queue()
	
	# FIXED: Don't update cursor when popup is open
	if camera and cursor_visualizer and not is_popup_open:
		_update_cursor()
		input_handler.handle_continuous_input(_delta)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE or what == NOTIFICATION_WM_CLOSE_REQUEST:
		if tilemap:
			tilemap.cleanup()

# ============================================================================
# INPUT HANDLING
# ============================================================================

func _input(event):
	# Block all input when popup is open (except closing the popup itself)
	if is_popup_open:
		return
	
	var result = input_handler.process_input(event, current_mode, current_tile_type, current_y_level)
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_F5:  # Or any key you want
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
		print("Mode: SELECT (Drag to select, F to fill, Delete/X to clear, R to rotate)")
	else:
		current_mode = EditorMode.EDIT
		selection_manager.clear_selection()
		print("Mode: EDIT")


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
	
	# FIXED: Hide/show cursor when hovering over material palette
	if cursor_visualizer:
		if is_hovered:
			cursor_visualizer.hide()
		else:
			# Only show if popup isn't open
			if not is_popup_open:
				cursor_visualizer.show()


func _on_popup_state_changed(is_open: bool):
	"""Handle popup state changes - disable camera input when popup is open"""
	is_popup_open = is_open
	
	if is_open:
		# Disable camera processing when popup opens
		camera.set_process(false)
		
		# FIXED: Hide cursor preview when popup opens
		if cursor_visualizer:
			cursor_visualizer.hide()
		
		print("Camera input disabled - popup opened")
	else:
		# Re-enable camera processing when popup closes
		camera.set_process(true)
		
		# FIXED: Show cursor preview when popup closes
		if cursor_visualizer:
			cursor_visualizer.show()
		
		print("Camera input enabled - popup closed")


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
		# Save to the currently loaded/saved file
		var filepath = current_save_file
		
		if LevelSaveLoad.save_level(tilemap, y_level_manager, filepath, material_palette):
			print("\n=== QUICK SAVE ===")
			var real_path = ProjectSettings.globalize_path(filepath)
			print("Saved to: ", real_path)
			print("==================\n")
	else:
		# No file loaded yet - open the save dialog instead
		print("No file loaded - opening Save As dialog...")
		show_save_dialog()


func save_level_with_name(level_name: String):
	var filepath = LevelSaveLoad.get_save_filepath(level_name)
	if LevelSaveLoad.save_level(tilemap, y_level_manager, filepath, material_palette):
		print("\n=== LEVEL SAVED ===")
		print("Saved to: ", filepath)
		print("===================\n")


func load_last_level():
	var levels = LevelSaveLoad.list_saved_levels()
	if levels.is_empty():
		print("No saved levels found")
		return
	
	# Sort by name (which includes timestamp) to get most recent
	levels.sort()
	var last_level = levels[-1]
	var filepath = "user://saved_levels/" + last_level
	
	if LevelSaveLoad.load_level(tilemap, y_level_manager, filepath, material_palette):
		print("\n=== LEVEL LOADED ===")
		print("Loaded from: ", filepath)
		print("====================\n")
		
		# Update grid visualizer to current y level
		y_level_manager.change_y_level(current_y_level)


func load_level_by_name(filename: String):
	var filepath = "user://saved_levels/" + filename
	if LevelSaveLoad.load_level(tilemap, y_level_manager, filepath, material_palette):
		print("\n=== LEVEL LOADED ===")
		print("Loaded from: ", filepath)
		print("====================\n")
		
		# Update grid visualizer to current y level
		y_level_manager.change_y_level(current_y_level)


func list_saved_levels():
	var levels = LevelSaveLoad.list_saved_levels()
	print("\n=== SAVED LEVELS ===")
	if levels.is_empty():
		print("No saved levels found")
	else:
		for level in levels:
			print("  - ", level)
	print("====================\n")

# ============================================================================
# FILE DIALOG HANDLERS
# ============================================================================

@onready var export_dialog: FileDialog = $UI/Export
@onready var save_dialog: FileDialog = $UI/Save
@onready var load_dialog: FileDialog = $UI/Load

func _on_export_confirmed(format_index: int, path: String):
	"""Handle export confirmation from export dialog"""
	print("\n=== EXPORTING LEVEL ===")
	print("Format: ", ["Single", "Chunks", "glTF"][format_index])
	print("Path: ", path)
	
	match format_index:
		0: # Single .tres
			_export_single_mesh(path)
		1: # Chunked .tres (path is directory)
			_export_chunked_meshes(path)
		2: # glTF
			_export_gltf(path)
	
	print("======================\n")


func _export_single_mesh(filepath: String):
	"""Export as single optimized mesh"""
	# Ensure .tres extension
	if not filepath.ends_with(".tres"):
		filepath += ".tres"
	
	tilemap.export_level_to_file(filepath, true)
	print("✓ Single mesh exported!")
	
	# Show actual path
	var real_path = ProjectSettings.globalize_path(filepath)
	print("Saved to: ", real_path)


func _export_chunked_meshes(directory: String):
	"""Export as chunked meshes"""
	# Extract folder name from path
	var save_name = directory.get_file()
	if save_name == "":
		save_name = "level_chunks"
	
	tilemap.export_level_chunked(save_name, Vector3i(32, 32, 32), true)
	print("✓ Chunked meshes exported!")
	
	# Show actual path
	var export_path = "user://exports/" + save_name + "/"
	var real_path = ProjectSettings.globalize_path(export_path)
	print("Saved to: ", real_path)


func _export_gltf(filepath: String):
	"""Export as glTF 2.0 with materials"""
	if not filepath.ends_with(".gltf") and not filepath.ends_with(".glb"):
		filepath += ".glb"
	
	print("\n=== EXPORTING glTF ===" )
	print("Path: ", filepath)
	
	var success = tilemap.export_level_gltf(filepath)
	if success:
		var real_path = ProjectSettings.globalize_path(filepath)
		print("✓ glTF export complete: ", real_path)
	else:
		push_error("glTF export failed — check output log for details")


func _on_save_confirmed(path: String):
	"""Handle save confirmation from save dialog"""
	if LevelSaveLoad.save_level(tilemap, y_level_manager, path, material_palette):
		current_save_file = path  # Remember this file for quick save
		print("\n=== LEVEL SAVED ===")
		var real_path = ProjectSettings.globalize_path(path)
		print("Saved to: ", real_path)
		print("===================\n")


func _on_load_confirmed(path: String):
	"""Handle load confirmation from load dialog"""
	if LevelSaveLoad.load_level(tilemap, y_level_manager, path, material_palette):
		current_save_file = path  # Remember this file for quick save
		print("\n=== LEVEL LOADED ===")
		var real_path = ProjectSettings.globalize_path(path)
		print("Loaded from: ", real_path)
		print("====================\n")
		
		# Clear undo/redo history — loaded state is the new baseline
		if undo_redo:
			undo_redo.clear()
		
		# Update grid visualizer to current y level
		y_level_manager.change_y_level(current_y_level)
	else:
		push_error("Failed to load level from: " + path)
		print("ERROR: Load failed!")


# ============================================================================
# FUNCTIONS TO SHOW FILE DIALOGS (call these from UI buttons)
# ============================================================================

func show_export_dialog():
	"""Show the export file dialog"""
	export_dialog.popup_centered_ratio(0.6)


func show_save_dialog():
	"""Show the save file dialog"""
	save_dialog.popup_centered_ratio(0.6)


func show_load_dialog():
	"""Show the load file dialog"""
	load_dialog.popup_centered_ratio(0.6)


func debug_corner_culling():
	"""Print corner culling debug info - call this after placing tiles"""
	if tilemap:
		tilemap.print_corner_debug()
	else:
		print("TileMap not initialized")
