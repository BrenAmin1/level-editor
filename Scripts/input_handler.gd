class_name InputHandler extends RefCounted

# Component handles all input processing for the level editor
var editor: Node3D  # Reference to main level_editor
var camera: CameraController
var tilemap: TileMap3D
var cursor_visualizer: CursorVisualizer
var selection_manager: SelectionManager
var y_level_manager: YLevelManager

# Input state
var mouse_pressed: bool = false
var current_mouse_button: InputEventMouseButton
var is_ui_hovered: bool = false

# Grid settings
var grid_size: float
var grid_range: int

# Current editor state (references from editor)
var current_mode: int  # EditorMode enum
var current_tile_type: int
var current_y_level: int

# ============================================================================
# SETUP
# ============================================================================

func setup(level_editor: Node3D, cam: CameraController, tm: TileMap3D, 
		   cursor_vis: CursorVisualizer, sel_mgr: SelectionManager, 
		   y_mgr: YLevelManager, grid_sz: float, grid_rng: int):
	editor = level_editor
	camera = cam
	tilemap = tm
	cursor_visualizer = cursor_vis
	selection_manager = sel_mgr
	y_level_manager = y_mgr
	grid_size = grid_sz
	grid_range = grid_rng

# ============================================================================
# INPUT PROCESSING
# ============================================================================

func process_input(event: InputEvent, mode: int, tile_type: int, y_level: int):
	current_mode = mode
	current_tile_type = tile_type
	current_y_level = y_level
	
	if event is InputEventMouseButton:
		_handle_mouse_button(event)
	elif event is InputEventMouseMotion:
		_handle_mouse_motion(event)
	elif event is InputEventKey and event.pressed:
		return _handle_keyboard(event)
	
	return null  # No mode change


func _handle_mouse_button(event: InputEventMouseButton):
	if is_ui_hovered:
		return
	
	if event.pressed:
		mouse_pressed = true
		current_mouse_button = event
		
		if current_mode == 1:  # SELECT mode
			if event.button_index == MOUSE_BUTTON_RIGHT:
				selection_manager.mass_delete_tiles()
			elif event.button_index == MOUSE_BUTTON_LEFT:
				selection_manager.start_selection(event.position)
	else:
		mouse_pressed = false
		if current_mode == 1 and event.button_index == MOUSE_BUTTON_LEFT:
			selection_manager.end_selection()


func _handle_mouse_motion(event: InputEventMouseMotion):
	camera.handle_mouse_motion(event)


func _handle_keyboard(event: InputEventKey) -> Dictionary:
	var result = {}
	
	# Save/Load shortcuts (highest priority - check first)
	if event.ctrl_pressed:
		# Quick save (Ctrl+S) - handled in level_editor._input()
		# We don't handle it here to avoid double-triggering
		if event.keycode == KEY_S and not event.shift_pressed:
			return result
		
		# Save with custom name (Ctrl+Shift+S) - handled in level_editor._input()
		elif event.keycode == KEY_S and event.shift_pressed:
			return result
		
		# Load (Ctrl+L) - handled in level_editor._input()
		elif event.keycode == KEY_L:
			return result
	
	# Regular editor controls
	match event.keycode:
		KEY_TAB:
			result["action"] = "toggle_mode"
		KEY_ENTER:
			editor.get_viewport().debug_draw = Viewport.DEBUG_DRAW_WIREFRAME
		KEY_BACKSPACE:
			editor.get_viewport().debug_draw = Viewport.DEBUG_DRAW_DISABLED
		KEY_1:
			result["tile_type"] = 0
			print("Selected: Floor tile (gray)")
		KEY_2:
			result["tile_type"] = 1
			print("Selected: Wall tile (brown)")
		KEY_3:
			result["tile_type"] = 3
			print("Selected: Custom")
		KEY_4:
			result["tile_type"] = 4
			print("Selected: Custom")
		KEY_BRACKETRIGHT, KEY_MINUS:
			result["y_level"] = current_y_level - 1
			y_level_manager.change_y_level(result["y_level"])
		KEY_BRACKETLEFT, KEY_EQUAL:
			result["y_level"] = current_y_level + 1
			y_level_manager.change_y_level(result["y_level"])
		KEY_F:
			if current_mode == 1:  # SELECT mode
				selection_manager.mass_place_tiles()
		KEY_DELETE, KEY_X:
			if current_mode == 1:  # SELECT mode
				selection_manager.mass_delete_tiles()
		KEY_R:
			if current_mode == 1:  # SELECT mode
				if event.shift_pressed:
					editor.rotate_selection_ccw()
				else:
					editor.rotate_selection_cw()
	
	return result


func handle_mouse_wheel(delta: float):
	camera.handle_mouse_wheel(delta)


func handle_continuous_input(_delta: float):
	# Block input if:
	# 1. Mouse is over UI (material palette, spinboxes, etc.)
	# 2. Window doesn't have focus
	if is_ui_hovered or not editor.window_has_focus:
		return
	
	# Handle held mouse buttons in EDIT mode
	if mouse_pressed and current_mode == 0:  # EDIT mode
		if current_mouse_button:
			current_mouse_button.position = editor.get_viewport().get_mouse_position()
			if current_mouse_button.button_index == MOUSE_BUTTON_LEFT:
				_attempt_tile_placement(current_mouse_button.position, false)
			elif current_mouse_button.button_index == MOUSE_BUTTON_RIGHT:
				_attempt_tile_removal(current_mouse_button.position)



# ============================================================================
# TILE PLACEMENT/REMOVAL
# ============================================================================

func _attempt_tile_placement(mouse_pos: Vector2, single_click: bool):
	var from = camera.project_ray_origin(mouse_pos)
	var to = from + camera.project_ray_normal(mouse_pos) * 1000
	
	var offset = y_level_manager.get_offset(current_y_level)
	var y_world = current_y_level * grid_size
	var placement_plane = Plane(Vector3.UP, y_world)
	var ray_dir = (to - from).normalized()
	var intersection = placement_plane.intersects_ray(from, ray_dir)
	
	if intersection:
		var adjusted_intersection = intersection - Vector3(offset.x, 0, offset.y)
		var grid_pos = Vector3i(
			floori(adjusted_intersection.x / grid_size),
			current_y_level,
			floori(adjusted_intersection.z / grid_size)
		)
		
		if abs(grid_pos.x) > grid_range or abs(grid_pos.z) > grid_range:
			return
		
		if not single_click and tilemap.has_tile(grid_pos):
			return
		
		tilemap.place_tile(grid_pos, current_tile_type)


func _attempt_tile_removal(mouse_pos: Vector2):
	var from = camera.project_ray_origin(mouse_pos)
	var to = from + camera.project_ray_normal(mouse_pos) * 1000
	
	var offset = y_level_manager.get_offset(current_y_level)
	var y_world = current_y_level * grid_size
	var placement_plane = Plane(Vector3.UP, y_world)
	var ray_dir = (to - from).normalized()
	var intersection = placement_plane.intersects_ray(from, ray_dir)
	
	if intersection:
		var adjusted_intersection = intersection - Vector3(offset.x, 0, offset.y)
		var grid_pos = Vector3i(
			floori(adjusted_intersection.x / grid_size),
			current_y_level,
			floori(adjusted_intersection.z / grid_size)
		)
		
		if tilemap.has_tile(grid_pos):
			tilemap.remove_tile(grid_pos)
