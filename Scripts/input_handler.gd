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

# Paint mode
var paint_mode: bool = false  # If true, only change materials without replacing tiles
var current_material_index: int = -1
var material_palette_ref = null  # Reference to material palette

# Grid settings
var grid_size: float
var grid_range: int

# Current editor state (references from editor)
var current_mode: int  # EditorMode enum
var current_tile_type: int
var current_y_level: int

# Focus management
var tracked_focus_controls: Array[Control] = []

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
# FOCUS MANAGEMENT
# ============================================================================

func register_focus_control(control: Control):
	"""Register a UI control for automatic focus management"""
	if control not in tracked_focus_controls:
		tracked_focus_controls.append(control)
		print("Registered focus control: ", control.name)

func _handle_focus_release(event: InputEvent) -> bool:
	"""
	Handle automatic focus release from UI elements.
	Returns true if focus was released and event should be consumed.
	"""
	# Release focus on Escape key
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		if _has_any_focus():
			_release_all_focus()
			return true  # Consume the event
	
	# Release focus when clicking on 3D viewport (outside UI)
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if _has_any_focus() and not is_ui_hovered:
			_release_all_focus()
			return false  # Don't consume - let click through to viewport
	
	return false

func _has_any_focus() -> bool:
	"""Check if any registered UI control has focus"""
	for control in tracked_focus_controls:
		if not is_instance_valid(control):
			continue
		
		if control is LineEdit and control.has_focus():
			return true
		elif control is SpinBox and control.get_line_edit().has_focus():
			return true
		elif control is TextEdit and control.has_focus():
			return true
	return false

func _release_all_focus():
	"""Release focus from all registered UI controls"""
	for control in tracked_focus_controls:
		if not is_instance_valid(control):
			continue
		
		if control is LineEdit:
			if control.has_focus():
				control.release_focus()
		elif control is SpinBox:
			if control.get_line_edit().has_focus():
				control.get_line_edit().release_focus()
		elif control is TextEdit:
			if control.has_focus():
				control.release_focus()
	
	print("Released all UI focus")

# ============================================================================
# MATERIAL PAINTING
# ============================================================================

func set_painting_material(material_index: int):
	"""Set the current material index for painting"""
	current_material_index = material_index

func set_material_palette_reference(palette):
	"""Set reference to material palette"""
	material_palette_ref = palette

func toggle_paint_mode():
	"""Toggle paint mode on/off"""
	paint_mode = not paint_mode
	if paint_mode:
		print("Paint Mode: ON (change materials without replacing tiles)")
	else:
		print("Paint Mode: OFF (normal tile placement)")

# ============================================================================
# INPUT PROCESSING
# ============================================================================

func process_input(event: InputEvent, mode: int, tile_type: int, y_level: int):
	current_mode = mode
	current_tile_type = tile_type
	current_y_level = y_level
	
	# Handle focus release first
	if _handle_focus_release(event):
		return null  # Focus was released, don't process other input
	
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
		if event.keycode == KEY_S and not event.shift_pressed:
			return result
		elif event.keycode == KEY_S and event.shift_pressed:
			return result
		elif event.keycode == KEY_L:
			return result
	
	# Regular editor controls
	match event.keycode:
		KEY_P:
			toggle_paint_mode()
		KEY_TAB:
			result["action"] = "toggle_mode"
		KEY_ENTER:
			editor.get_viewport().debug_draw = Viewport.DEBUG_DRAW_WIREFRAME
		KEY_BACKSPACE:
			editor.get_viewport().debug_draw = Viewport.DEBUG_DRAW_DISABLED
		KEY_1:
			result["tile_type"] = 0
			print("Selected: Custom mesh 1")
		KEY_2:
			result["tile_type"] = 1
			print("Selected: Custom mesh 2")
		KEY_BRACKETRIGHT, KEY_MINUS:
			result["y_level"] = current_y_level - 1
			y_level_manager.change_y_level(result["y_level"])
		KEY_BRACKETLEFT, KEY_EQUAL:
			result["y_level"] = current_y_level + 1
			y_level_manager.change_y_level(result["y_level"])
		KEY_F:
			if current_mode == 1:  # SELECT mode
				selection_manager.mass_place_tiles(current_material_index)
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
	# 3. Any UI control has focus
	if is_ui_hovered or not editor.window_has_focus or _has_any_focus():
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
		
		# Paint mode: only change material on existing tiles
		if paint_mode and tilemap.has_tile(grid_pos):
			if current_material_index >= 0 and material_palette_ref:
				tilemap.apply_material_to_tile(grid_pos, current_material_index, material_palette_ref)
				var material_data = material_palette_ref.get_material_data_at_index(current_material_index)
				var material_name = material_data.get("name", "Unknown")
				if single_click:
					print("Painted tile at ", grid_pos, " with material: ", material_name)
			return
		
		# Normal placement mode
		if not single_click and tilemap.has_tile(grid_pos):
			return
		
		# Place tile with material if selected
		if current_material_index >= 0 and material_palette_ref:
			tilemap.place_tile_with_material(grid_pos, current_tile_type, current_material_index, material_palette_ref)
		else:
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
		
		if abs(grid_pos.x) > grid_range or abs(grid_pos.z) > grid_range:
			return
		
		tilemap.remove_tile(grid_pos)

func set_ui_hovered(hovered: bool):
	is_ui_hovered = hovered
