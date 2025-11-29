extends Node3D

# ============================================================================
# COMPONENTS
# ============================================================================
@onready var camera: CameraController = $Camera3D
@onready var grid_visualizer: GridVisualizer = $GridVisualizer
@onready var cursor_visualizer: CursorVisualizer = $CursorVisualizer

var tilemap: TileMap3D
var input_handler: InputHandler
var selection_manager: SelectionManager
var y_level_manager: YLevelManager

# ============================================================================
# EDITOR STATE
# ============================================================================
enum EditorMode { EDIT, SELECT }
var current_mode: EditorMode = EditorMode.EDIT
var current_tile_type = 0
var current_y_level = 0
var grid_size = 1.0
var rotation_increment: float = 15.0  # degrees

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
	
	# Initialize TileMap3D
	tilemap = TileMap3D.new(grid_size)
	tilemap.set_parent(self)
	tilemap.set_offset_provider(Callable(self, "get_y_level_offset"))
	
	# Load custom mesh
	tilemap.load_obj_for_tile_type(3, "res://cube_bulge.obj")
	tilemap.set_custom_material(3, 0, GRASS)
	tilemap.set_custom_material(3, 1, DIRT)
	tilemap.set_custom_material(3, 2, DIRT)
	tilemap.load_obj_for_tile_type(4, "res://half_bevel.obj")
	tilemap.set_custom_material(4, 0, GRASS)
	tilemap.set_custom_material(4, 1, DIRT)
	tilemap.set_custom_material(4, 2, DIRT)
	
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
	
	print("Mode: EDIT (Press TAB to toggle)")
	print("\nSave/Load Controls:")
	print("  Ctrl+S - Quick save")
	print("  Ctrl+L - Load last save")
	print("  Ctrl+Shift+S - Save with custom name")

# ============================================================================
# MAIN LOOP
# ============================================================================

func _process(_delta):
	selection_manager.process_queue()
	if camera and cursor_visualizer:
		_update_cursor()
		input_handler.handle_continuous_input(_delta)

# ============================================================================
# INPUT HANDLING
# ============================================================================

func _input(event):
	var result = input_handler.process_input(event, current_mode, current_tile_type, current_y_level)
	
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
	if Input.is_action_just_pressed("export"):
		export_current_level()
	if Input.is_action_just_pressed("chunk_export"):
		export_current_level_chunked()
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
	var filepath = LevelSaveLoad.get_save_filepath("quicksave")
	if LevelSaveLoad.save_level(tilemap, y_level_manager, filepath):
		print("\n=== QUICK SAVE ===")
		print("Saved to: ", filepath)
		print("==================\n")


func save_level_with_name(level_name: String):
	var filepath = LevelSaveLoad.get_save_filepath(level_name)
	if LevelSaveLoad.save_level(tilemap, y_level_manager, filepath):
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
	
	if LevelSaveLoad.load_level(tilemap, y_level_manager, filepath):
		print("\n=== LEVEL LOADED ===")
		print("Loaded from: ", filepath)
		print("====================\n")
		
		# Update grid visualizer to current y level
		y_level_manager.change_y_level(current_y_level)


func load_level_by_name(filename: String):
	var filepath = "user://saved_levels/" + filename
	if LevelSaveLoad.load_level(tilemap, y_level_manager, filepath):
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
# EXPORT FUNCTIONS (Mesh Export - separate from save/load)
# ============================================================================

func export_current_level():
	var timestamp = Time.get_datetime_string_from_system().replace(":", "-")
	var filename = "res://exported_level_" + timestamp + ".tres"
	print("\n=== EXPORTING LEVEL ===")
	tilemap.export_level_to_file(filename, true)
	print("Saved to: ", filename)
	print("======================\n")


func export_current_level_single_material():
	var timestamp = Time.get_datetime_string_from_system().replace(":", "-")
	var filename = "res://exported_level_single_" + timestamp + ".tres"
	print("\n=== EXPORTING LEVEL (Single Material) ===")
	tilemap.export_level_to_file(filename, false)
	print("Saved to: ", filename)
	print("=========================================\n")

func export_current_level_chunked():
	var timestamp = Time.get_datetime_string_from_system().replace(":", "-")
	var save_name = "level_" + timestamp
	
	print("\n=== EXPORTING LEVEL (CHUNKED) ===")
	tilemap.export_level_chunked(save_name, Vector3i(32, 32, 32), true)
	print("==================================\n")
