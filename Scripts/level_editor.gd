extends Node3D

# Components
@onready var camera: CameraController = $Camera3D
@onready var grid_visualizer: GridVisualizer = $GridVisualizer
@onready var cursor_visualizer: CursorVisualizer = $CursorVisualizer

var tilemap: TileMap3D

# Editor mode
enum EditorMode { EDIT, SELECT }
var current_mode: EditorMode = EditorMode.EDIT

# Editor state
var current_tile_type = 0
var current_y_level = 0
var grid_size = 1.0

# Y-level offsets: Dictionary[int, Vector2] - maps y_level to (x_offset, z_offset)
var y_level_offsets: Dictionary = {}

# Mouse handling
var mouse_pressed: bool = false
var current_mouse_button: InputEventMouseButton

# Selection state
var selection_start: Vector3i
var selection_end: Vector3i
var is_selecting: bool = false
var has_selection : bool = false
var selection_visualizer: MeshInstance3D

# Grid settings
@export var grid_range: int = 100

func _ready():
	# Initialize tilemap
	tilemap = TileMap3D.new(grid_size)
	tilemap.set_parent(self)
	tilemap.set_offset_provider(Callable(self, "get_y_level_offset"))
	tilemap.load_obj_for_tile_type(3, "res://cube_bulge.obj")
	# Create selection visualizer
	create_selection_visualizer()
	
	print("Mode: EDIT (Press TAB to toggle)")

func _process(_delta):
	if camera:
		update_cursor_position()
		if mouse_pressed:
			current_mouse_button.position = get_viewport().get_mouse_position()
			handle_mouse_click(current_mouse_button)

func update_cursor_position():
	if not camera or not cursor_visualizer:
		return
	
	var viewport = get_viewport()
	if not viewport:
		return
	
	var mouse_pos = viewport.get_mouse_position()
	var from = camera.project_ray_origin(mouse_pos)
	var to = from + camera.project_ray_normal(mouse_pos) * 1000
	
	# Get offset for current Y level
	var offset = get_y_level_offset(current_y_level)
	
	# Create a plane at the current Y level
	var y_world = current_y_level * grid_size
	var placement_plane = Plane(Vector3.UP, y_world)
	var intersection = placement_plane.intersects_ray(from, to - from)
	
	if intersection:
		# Apply offset to intersection point
		var adjusted_intersection = intersection - Vector3(offset.x, 0, offset.y)
		
		var grid_pos = Vector3i(
			floori(adjusted_intersection.x / grid_size),
			current_y_level,
			floori(adjusted_intersection.z / grid_size)
		)
		
		# CLAMP TO GRID RANGE
		if abs(grid_pos.x) > grid_range or abs(grid_pos.z) > grid_range:
			return  # Outside allowed bounds
		
		# Update selection end if selecting
		if is_selecting and current_mode == EditorMode.SELECT:
			selection_end = grid_pos
			update_selection_visualizer()
		
		var tile_exists = tilemap.has_tile(grid_pos)
		cursor_visualizer.update_cursor_with_offset(camera, current_y_level, tile_exists, offset)

func _input(event):
	# Handle mouse button press
	if event is InputEventMouseButton and event.pressed:
		mouse_pressed = true
		current_mouse_button = event
		if current_mode == EditorMode.SELECT and event.button_index == MOUSE_BUTTON_RIGHT:
			mass_delete_tiles()
			
		# Start selection in SELECT mode
		if current_mode == EditorMode.SELECT and event.button_index == MOUSE_BUTTON_LEFT:
			has_selection = true
			start_selection(event.position)
		
	elif event is InputEventMouseButton and event.is_released():
		mouse_pressed = false
		# End selection in SELECT mode
		if current_mode == EditorMode.SELECT and event.button_index == MOUSE_BUTTON_LEFT and is_selecting:
			has_selection = true
			end_selection()
	
	# Camera rotation
	if event is InputEventMouseMotion:
		camera.handle_mouse_motion(event)
	
	# Mouse wheel for FOV
	if event is InputEventMouse and not Engine.is_editor_hint():
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_WHEEL_DOWN):
			camera.handle_mouse_wheel(1.0)
		elif Input.is_mouse_button_pressed(MOUSE_BUTTON_WHEEL_UP):
			camera.handle_mouse_wheel(-1.0)
	
	# Reset FOV
	if Input.is_action_just_pressed("reset_fov"):
		camera.reset_fov()
	
	# Keyboard shortcuts
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_TAB:
			toggle_mode()
		elif event.keycode == KEY_ENTER:
			get_viewport().debug_draw = Viewport.DEBUG_DRAW_WIREFRAME
		elif event.keycode == KEY_BACKSPACE:
			get_viewport().debug_draw = Viewport.DEBUG_DRAW_DISABLED
		elif event.keycode == KEY_1:
			current_tile_type = 0
			print("Selected: Floor tile (gray)")
		elif event.keycode == KEY_2:
			current_tile_type = 1
			print("Selected: Wall tile (brown)")
		elif event.keycode == KEY_3:
			current_tile_type = 3
			print("Selected: Custom")
		elif event.keycode == KEY_BRACKETRIGHT or event.keycode == KEY_MINUS:
			current_y_level -= 1
			print("Y-Level: ", current_y_level)
			var offset = get_y_level_offset(current_y_level)
			grid_visualizer.set_y_level_offset(current_y_level, offset)
		elif event.keycode == KEY_BRACKETLEFT or event.keycode == KEY_EQUAL:
			current_y_level += 1
			print("Y-Level: ", current_y_level)
			var offset = get_y_level_offset(current_y_level)
			grid_visualizer.set_y_level_offset(current_y_level, offset)
		# Mass operations in SELECT mode
		elif current_mode == EditorMode.SELECT:
			if event.keycode == KEY_F and has_selection:
				mass_place_tiles()
			elif event.keycode == KEY_DELETE or event.keycode == KEY_X and has_selection:
				mass_delete_tiles()

func toggle_mode():
	if current_mode == EditorMode.EDIT:
		current_mode = EditorMode.SELECT
		print("Mode: SELECT (Drag to select area, F to fill, Delete/X to clear)")
	else:
		current_mode = EditorMode.EDIT
		clear_selection()
		print("Mode: EDIT")

# Get offset for a specific Y level
func get_y_level_offset(y_level: int) -> Vector2:
	return y_level_offsets.get(y_level, Vector2.ZERO)

# Set offset for a specific Y level
func set_y_level_offset(y_level: int, x_offset: float, z_offset: float):
	y_level_offsets[y_level] = Vector2(x_offset, z_offset)
	# Update all tiles at this Y level
	tilemap.refresh_y_level(y_level)
	# Update grid and cursor visualizers
	grid_visualizer.set_y_level_offset(current_y_level, get_y_level_offset(current_y_level))

# Clear offset for a specific Y level
func clear_y_level_offset(y_level: int):
	y_level_offsets.erase(y_level)
	tilemap.refresh_y_level(y_level)
	grid_visualizer.set_y_level_offset(current_y_level, Vector2.ZERO)

func start_selection(mouse_pos: Vector2):
	var from = camera.project_ray_origin(mouse_pos)
	var to = from + camera.project_ray_normal(mouse_pos) * 1000
	
	var offset = get_y_level_offset(current_y_level)
	
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
		
		# CLAMP TO GRID RANGE
		if abs(grid_pos.x) > grid_range or abs(grid_pos.z) > grid_range:
			return
		
		selection_start = grid_pos
		selection_end = grid_pos
		is_selecting = true
		update_selection_visualizer()

func end_selection():
	is_selecting = false
	print("Selected area: ", selection_start, " to ", selection_end)

func clear_selection():
	is_selecting = false
	has_selection = false
	if selection_visualizer:
		selection_visualizer.visible = false

func create_selection_visualizer():
	selection_visualizer = MeshInstance3D.new()
	var immediate_mesh = ImmediateMesh.new()
	selection_visualizer.mesh = immediate_mesh
	
	var material = StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(0.2, 0.6, 1.0, 0.3)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS
	selection_visualizer.material_override = material
	
	selection_visualizer.visible = false
	add_child(selection_visualizer)

func update_selection_visualizer():
	if not selection_visualizer:
		return
	
	var immediate_mesh = ImmediateMesh.new()
	selection_visualizer.mesh = immediate_mesh
	
	# Calculate bounds
	var min_x = mini(selection_start.x, selection_end.x)
	var max_x = maxi(selection_start.x, selection_end.x)
	var min_z = mini(selection_start.z, selection_end.z)
	var max_z = maxi(selection_start.z, selection_end.z)
	
	var offset = get_y_level_offset(current_y_level)
	var y = current_y_level * grid_size
	var s = grid_size
	
	# Create filled quads for the selection area
	var surface_array = []
	surface_array.resize(Mesh.ARRAY_MAX)
	
	var verts = PackedVector3Array()
	var indices = PackedInt32Array()
	var normals = PackedVector3Array()
	
	# Top face
	for x in range(min_x, max_x + 1):
		for z in range(min_z, max_z + 1):
			var pos = Vector3(x * s + offset.x, y + 0.01, z * s + offset.y)
			var start_idx = verts.size()
			
			verts.append_array([
				pos,
				pos + Vector3(s, 0, 0),
				pos + Vector3(s, 0, s),
				pos + Vector3(0, 0, s)
			])
			
			normals.append_array([
				Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP
			])
			
			indices.append_array([
				start_idx, start_idx + 1, start_idx + 2,
				start_idx, start_idx + 2, start_idx + 3
			])
	
	surface_array[Mesh.ARRAY_VERTEX] = verts
	surface_array[Mesh.ARRAY_INDEX] = indices
	surface_array[Mesh.ARRAY_NORMAL] = normals
	
	var mesh = ArrayMesh.new()
	if verts.size() > 0:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface_array)
	
	selection_visualizer.mesh = mesh
	selection_visualizer.visible = true

func mass_place_tiles():
	if not is_selecting and selection_start == selection_end:
		print("No area selected")
		return
	
	var min_x = mini(selection_start.x, selection_end.x)
	var max_x = maxi(selection_start.x, selection_end.x)
	var min_z = mini(selection_start.z, selection_end.z)
	var max_z = maxi(selection_start.z, selection_end.z)
	
	var count = 0
	for x in range(min_x, max_x + 1):
		for z in range(min_z, max_z + 1):
			var pos = Vector3i(x, current_y_level, z)
			if abs(pos.x) <= grid_range and abs(pos.z) <= grid_range:
				tilemap.place_tile(pos, current_tile_type)
				count += 1
	
	print("Placed ", count, " tiles")
	clear_selection()

func mass_delete_tiles():
	if not is_selecting and selection_start == selection_end:
		print("No area selected")
		return
	
	var min_x = mini(selection_start.x, selection_end.x)
	var max_x = maxi(selection_start.x, selection_end.x)
	var min_z = mini(selection_start.z, selection_end.z)
	var max_z = maxi(selection_start.z, selection_end.z)
	
	var count = 0
	for x in range(min_x, max_x + 1):
		for z in range(min_z, max_z + 1):
			var pos = Vector3i(x, current_y_level, z)
			if tilemap.has_tile(pos):
				tilemap.remove_tile(pos)
				count += 1
	
	print("Deleted ", count, " tiles")
	clear_selection()

func handle_mouse_click(event: InputEventMouseButton):
	if not camera:
		return
	
	# Only allow placement/removal in EDIT mode
	if current_mode == EditorMode.EDIT:
		if event.button_index == MOUSE_BUTTON_LEFT:
			attempt_tile_placement(event.position, true)
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			attempt_tile_removal(event.position)

func attempt_tile_placement(mouse_pos: Vector2, single_click: bool):
	var from = camera.project_ray_origin(mouse_pos)
	var to = from + camera.project_ray_normal(mouse_pos) * 1000
	
	var offset = get_y_level_offset(current_y_level)
	
	# Create a plane at the current Y level
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
		
		# CLAMP TO GRID RANGE
		if abs(grid_pos.x) > grid_range or abs(grid_pos.z) > grid_range:
			return  # Outside allowed bounds
		
		# In editor mode with mouse held, only place if tile doesn't exist
		if not single_click and tilemap.has_tile(grid_pos):
			return
		
		tilemap.place_tile(grid_pos, current_tile_type)

func attempt_tile_removal(mouse_pos: Vector2):
	if not camera:
		return
	
	var from = camera.project_ray_origin(mouse_pos)
	var to = from + camera.project_ray_normal(mouse_pos) * 1000
	
	var offset = get_y_level_offset(current_y_level)
	
	# First try plane intersection at current Y level
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
