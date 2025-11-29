class_name SelectionManager extends RefCounted

# Manages selection box and mass operations
var tilemap: TileMap3D
var camera: CameraController
var y_level_manager: YLevelManager

# Selection state
var selection_start: Vector3i
var selection_end: Vector3i
var is_selecting: bool = false
var has_selection: bool = false

# Visualization
var selection_visualizer: MeshInstance3D

# Settings
var grid_size: float
var grid_range: int
var current_y_level: int
var current_tile_type: int

# Async processing
var is_processing: bool = false
var processing_queue: Array = []
var processing_type: String = ""
var tiles_per_frame: int = 100  # Process this many tiles per frame
var batch_mode: bool = false  # Track if we're in batch operation
var tiles_placed: Array = []  # Track tiles placed for batch update

# ============================================================================
# SETUP
# ============================================================================

func setup(tm: TileMap3D, cam: CameraController, y_mgr: YLevelManager, 
		   grid_sz: float, grid_rng: int, parent: Node3D):
	tilemap = tm
	camera = cam
	y_level_manager = y_mgr
	grid_size = grid_sz
	grid_range = grid_rng
	
	_create_selection_visualizer(parent)


func update_state(y_level: int, tile_type: int):
	current_y_level = y_level
	current_tile_type = tile_type

# ============================================================================
# SELECTION
# ============================================================================

func start_selection(mouse_pos: Vector2):
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
		
		selection_start = grid_pos
		selection_end = grid_pos
		is_selecting = true
		has_selection = true
		update_visualizer()


func update_selection(mouse_pos: Vector2):
	if not is_selecting:
		return
	
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
		
		selection_end = grid_pos
		update_visualizer()


func end_selection():
	is_selecting = false
	print("Selected area: ", selection_start, " to ", selection_end)


func clear_selection():
	is_selecting = false
	has_selection = false
	if selection_visualizer:
		selection_visualizer.visible = false

# ============================================================================
# MASS OPERATIONS - ASYNC PROCESSING
# ============================================================================

func mass_place_tiles():
	if not has_selection:
		print("No area selected")
		return
	
	if is_processing:
		print("Already processing operation")
		return
	
	var min_x = mini(selection_start.x, selection_end.x)
	var max_x = maxi(selection_start.x, selection_end.x)
	var min_z = mini(selection_start.z, selection_end.z)
	var max_z = maxi(selection_start.z, selection_end.z)
	
	# Build queue of positions
	processing_queue.clear()
	tiles_placed.clear()
	for x in range(min_x, max_x + 1):
		for z in range(min_z, max_z + 1):
			var pos = Vector3i(x, current_y_level, z)
			if abs(pos.x) <= grid_range and abs(pos.z) <= grid_range:
				processing_queue.append(pos)
	
	if processing_queue.is_empty():
		clear_selection()
		return
	
	is_processing = true
	batch_mode = true
	processing_type = "place"
	
	# Enable batch mode on tilemap to defer mesh updates
	tilemap.set_batch_mode(true)
	
	print("Queued ", processing_queue.size(), " tiles for placement...")


func mass_delete_tiles():
	if not has_selection:
		print("No area selected")
		return
	
	if is_processing:
		print("Already processing operation")
		return
	
	var min_x = mini(selection_start.x, selection_end.x)
	var max_x = maxi(selection_start.x, selection_end.x)
	var min_z = mini(selection_start.z, selection_end.z)
	var max_z = maxi(selection_start.z, selection_end.z)
	
	# Build queue of positions with tiles
	processing_queue.clear()
	tiles_placed.clear()
	for x in range(min_x, max_x + 1):
		for z in range(min_z, max_z + 1):
			var pos = Vector3i(x, current_y_level, z)
			if tilemap.has_tile(pos):
				processing_queue.append(pos)
	
	if processing_queue.is_empty():
		print("No tiles to delete")
		clear_selection()
		return
	
	is_processing = true
	batch_mode = true
	processing_type = "delete"
	
	# Enable batch mode on tilemap to defer mesh updates
	if tilemap.has_method("set_batch_mode"):
		tilemap.set_batch_mode(true)
	
	print("Queued ", processing_queue.size(), " tiles for deletion...")


# Call this from your main loop (_process or _physics_process)
func process_queue():
	if not is_processing or processing_queue.is_empty():
		if is_processing and processing_queue.is_empty():
			_finish_processing()
		return
	
	# Process a batch of tiles this frame
	var processed = 0
	while processed < tiles_per_frame and not processing_queue.is_empty():
		var item = processing_queue.pop_front()
		
		if processing_type == "place":
			tilemap.place_tile(item, current_tile_type)
			tiles_placed.append(item)
		elif processing_type == "delete":
			tilemap.remove_tile(item)
			tiles_placed.append(item)
		elif processing_type == "rotate":
			# item is a dictionary with pos, type, and rotation
			tilemap.set_tile_rotation(item["pos"], item["rotation"])
			tiles_placed.append(item["pos"])
		
		processed += 1
	
	# Optional: print progress every 500 tiles
	if processing_queue.size() % 500 == 0 and processing_queue.size() > 0:
		print("Remaining: ", processing_queue.size())


func _finish_processing():
	print("Completed ", processing_type, " operation")
	
	# Exit batch mode and trigger all deferred updates
	if batch_mode:
		tilemap.set_batch_mode(false)
	
	is_processing = false
	batch_mode = false
	processing_queue.clear()
	tiles_placed.clear()
	processing_type = ""
	clear_selection()


func is_busy() -> bool:
	return is_processing


func get_progress() -> float:
	if not is_processing:
		return 0.0
	
	var total = processing_queue.size() + tiles_per_frame  # Approximate
	return 1.0 - (float(processing_queue.size()) / total)

# ============================================================================
# VISUALIZATION
# ============================================================================

func _create_selection_visualizer(parent: Node3D):
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
	parent.add_child(selection_visualizer)


func update_visualizer():
	if not selection_visualizer or not has_selection:
		return
	
	var min_x = mini(selection_start.x, selection_end.x)
	var max_x = maxi(selection_start.x, selection_end.x)
	var min_z = mini(selection_start.z, selection_end.z)
	var max_z = maxi(selection_start.z, selection_end.z)
	
	var offset = y_level_manager.get_offset(current_y_level)
	var y = current_y_level * grid_size
	var s = grid_size
	
	var verts = PackedVector3Array()
	var indices = PackedInt32Array()
	var normals = PackedVector3Array()
	
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
	
	var surface_array = []
	surface_array.resize(Mesh.ARRAY_MAX)
	surface_array[Mesh.ARRAY_VERTEX] = verts
	surface_array[Mesh.ARRAY_INDEX] = indices
	surface_array[Mesh.ARRAY_NORMAL] = normals
	
	var mesh = ArrayMesh.new()
	if verts.size() > 0:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface_array)
	
	selection_visualizer.mesh = mesh
	selection_visualizer.visible = true


# ============================================================================
# ADD: New rotation function to selection_manager.gd
# ============================================================================

func rotate_selected_tiles(degrees: float):
	if not has_selection:
		print("No area selected")
		return
	
	if is_processing:
		print("Already processing operation")
		return
	
	var min_x = mini(selection_start.x, selection_end.x)
	var max_x = maxi(selection_start.x, selection_end.x)
	var min_z = mini(selection_start.z, selection_end.z)
	var max_z = maxi(selection_start.z, selection_end.z)
	
	# Collect all tiles in selection with their types and rotations
	var tiles_to_rotate = []
	for x in range(min_x, max_x + 1):
		for z in range(min_z, max_z + 1):
			var pos = Vector3i(x, current_y_level, z)
			if tilemap.has_tile(pos):
				var current_rotation = tilemap.get_tile_rotation(pos)
				var new_rotation = fmod(current_rotation + degrees + 360.0, 360.0)
				
				tiles_to_rotate.append({
					"pos": pos,
					"rotation": new_rotation
				})
	
	if tiles_to_rotate.is_empty():
		print("No tiles to rotate in selection")
		return
	
	# Queue rotation operations
	processing_queue.clear()
	tiles_placed.clear()
	processing_queue = tiles_to_rotate.duplicate()
	
	is_processing = true
	batch_mode = true
	processing_type = "rotate"
	
	tilemap.set_batch_mode(true)
	
	print("Rotating ", processing_queue.size(), " tiles by ", degrees, " degrees...")
