extends Node3D

# Camera reference
@onready var camera: Camera3D = $Camera3D

# Tile storage
var tiles = {}  # Vector3i -> tile_type
var tile_meshes = {}  # Vector3i -> MeshInstance3D

var mouse_pressed : bool = false
var current_mouse_button : InputEventMouseButton

# Editor state
var current_tile_type = 0
var current_y_level = 0  # Current Y level for placement
var grid_size = 1.0
var last_debug_pos = Vector2.ZERO  # Track last debug position

# Camera rotation state
var camera_rotation : Vector2 = Vector2.ZERO  # x = pitch, y = yaw
var mouse_sensitivity : float = 0.003


var grid_mesh: MeshInstance3D
var grid_highlight: MeshInstance3D  # Highlight for current Y level
var cursor_preview: MeshInstance3D  # Preview block at cursor position
var cursor_outline: MeshInstance3D  # Outline for hovered cell
var ray_visualizer: MeshInstance3D  # Visualize the raycast
var intersection_marker: MeshInstance3D  # Shows exact ray/plane intersection

# Grid settings
@export var grid_range : int = 100  # How many grid lines in each direction

func _ready():
	create_grid()
	create_grid_highlight()
	create_cursor_preview()
	create_cursor_outline()
	create_ray_visualizer()
	create_intersection_marker()

func _process(delta):
	if camera:
		handle_camera_movement(delta)
		handle_camera_rotation()
		update_cursor_position()
		if mouse_pressed:
			current_mouse_button.position = get_viewport().get_mouse_position()
			handle_mouse_click(current_mouse_button)

func create_grid():
	# Create a visual 3D grid - only vertical lines
	if grid_mesh:
		grid_mesh.queue_free()
	
	grid_mesh = MeshInstance3D.new()
	var immediate_mesh = ImmediateMesh.new()
	grid_mesh.mesh = immediate_mesh
	
	# Create material for grid lines
	var material = StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(0.3, 0.3, 0.3, 0.3)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS
	grid_mesh.material_override = material
	
	add_child(grid_mesh)
	
	# Set owner for editor mode
	if Engine.is_editor_hint():
		grid_mesh.owner = get_tree().edited_scene_root
	
	update_grid_lines()

func update_grid_lines():
	if not grid_mesh:
		return
	
	var immediate_mesh = ImmediateMesh.new()
	grid_mesh.mesh = immediate_mesh
	
	immediate_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	
	# Use grid_size consistently
	var y = current_y_level * grid_size
	
	# Draw vertical lines only at current Y level
	for x in range(-grid_range, grid_range + 1):
		for z in range(-grid_range, grid_range + 1):
			var x_pos = x * grid_size
			var z_pos = z * grid_size
			
			# Short vertical line at this grid point
			immediate_mesh.surface_add_vertex(Vector3(x_pos, y, z_pos))
			immediate_mesh.surface_add_vertex(Vector3(x_pos, y + grid_size * 0.1, z_pos))
	
	immediate_mesh.surface_end()

func create_cursor_preview():
	# Create a semi-transparent preview block at cursor position
	cursor_preview = MeshInstance3D.new()
	
	# Create box mesh using ArrayMesh
	var box_mesh = create_box_mesh(grid_size)
	cursor_preview.mesh = box_mesh
	
	var material = StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(1.0, 1.0, 0.0, 0.3)  # Yellow semi-transparent
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS
	cursor_preview.material_override = material
	
	cursor_preview.visible = false
	add_child(cursor_preview)
	
	if Engine.is_editor_hint():
		cursor_preview.owner = get_tree().edited_scene_root

func create_cursor_outline():
	# Create an outlined box to show which cell is being hovered
	cursor_outline = MeshInstance3D.new()
	
	# Create wireframe box mesh
	var immediate_mesh = ImmediateMesh.new()
	cursor_outline.mesh = immediate_mesh
	
	var material = StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(1.0, 1.0, 1.0, 0.8)  # White outline
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS
	cursor_outline.material_override = material
	
	cursor_outline.visible = false
	add_child(cursor_outline)
	
	if Engine.is_editor_hint():
		cursor_outline.owner = get_tree().edited_scene_root

func update_cursor_outline(grid_pos: Vector3i):
	if not cursor_outline:
		return
	
	var immediate_mesh = ImmediateMesh.new()
	cursor_outline.mesh = immediate_mesh
	
	var s = grid_size
	var pos = grid_to_world(grid_pos)
	
	immediate_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	
	# Bottom square
	immediate_mesh.surface_add_vertex(pos + Vector3(0, 0, 0))
	immediate_mesh.surface_add_vertex(pos + Vector3(s, 0, 0))
	immediate_mesh.surface_add_vertex(pos + Vector3(s, 0, 0))
	immediate_mesh.surface_add_vertex(pos + Vector3(s, 0, s))
	immediate_mesh.surface_add_vertex(pos + Vector3(s, 0, s))
	immediate_mesh.surface_add_vertex(pos + Vector3(0, 0, s))
	immediate_mesh.surface_add_vertex(pos + Vector3(0, 0, s))
	immediate_mesh.surface_add_vertex(pos + Vector3(0, 0, 0))
	
	# Top square
	immediate_mesh.surface_add_vertex(pos + Vector3(0, s, 0))
	immediate_mesh.surface_add_vertex(pos + Vector3(s, s, 0))
	immediate_mesh.surface_add_vertex(pos + Vector3(s, s, 0))
	immediate_mesh.surface_add_vertex(pos + Vector3(s, s, s))
	immediate_mesh.surface_add_vertex(pos + Vector3(s, s, s))
	immediate_mesh.surface_add_vertex(pos + Vector3(0, s, s))
	immediate_mesh.surface_add_vertex(pos + Vector3(0, s, s))
	immediate_mesh.surface_add_vertex(pos + Vector3(0, s, 0))
	
	# Vertical edges
	immediate_mesh.surface_add_vertex(pos + Vector3(0, 0, 0))
	immediate_mesh.surface_add_vertex(pos + Vector3(0, s, 0))
	immediate_mesh.surface_add_vertex(pos + Vector3(s, 0, 0))
	immediate_mesh.surface_add_vertex(pos + Vector3(s, s, 0))
	immediate_mesh.surface_add_vertex(pos + Vector3(s, 0, s))
	immediate_mesh.surface_add_vertex(pos + Vector3(s, s, s))
	immediate_mesh.surface_add_vertex(pos + Vector3(0, 0, s))
	immediate_mesh.surface_add_vertex(pos + Vector3(0, s, s))
	
	immediate_mesh.surface_end()
	
	cursor_outline.visible = true

func create_box_mesh(size: float) -> ArrayMesh:
	var surface_array = []
	surface_array.resize(Mesh.ARRAY_MAX)
	
	var verts = PackedVector3Array()
	var indices = PackedInt32Array()
	var normals = PackedVector3Array()
	var uvs = PackedVector2Array()
	
	# Create a cube centered at origin
	var s = size
	
	# Front face (Z-)
	add_quad(verts, indices, normals, uvs,
		Vector3(0, 0, 0), Vector3(s, 0, 0),
		Vector3(s, s, 0), Vector3(0, s, 0),
		Vector3(0, 0, -1))
	
	# Back face (Z+)
	add_quad(verts, indices, normals, uvs,
		Vector3(s, 0, s), Vector3(0, 0, s),
		Vector3(0, s, s), Vector3(s, s, s),
		Vector3(0, 0, 1))
	
	# Right face (X+)
	add_quad(verts, indices, normals, uvs,
		Vector3(s, 0, 0), Vector3(s, 0, s),
		Vector3(s, s, s), Vector3(s, s, 0),
		Vector3(1, 0, 0))
	
	# Left face (X-)
	add_quad(verts, indices, normals, uvs,
		Vector3(0, 0, s), Vector3(0, 0, 0),
		Vector3(0, s, 0), Vector3(0, s, s),
		Vector3(-1, 0, 0))
	
	# Top face (Y+)
	add_quad(verts, indices, normals, uvs,
		Vector3(0, s, 0), Vector3(s, s, 0),
		Vector3(s, s, s), Vector3(0, s, s),
		Vector3(0, 1, 0))
	"""
	# Bottom face (Y-)
	add_quad(verts, indices, normals, uvs,
		Vector3(0, 0, s), Vector3(s, 0, s),
		Vector3(s, 0, 0), Vector3(0, 0, 0),
		Vector3(0, -1, 0))
	"""

	surface_array[Mesh.ARRAY_VERTEX] = verts
	surface_array[Mesh.ARRAY_INDEX] = indices
	surface_array[Mesh.ARRAY_NORMAL] = normals
	surface_array[Mesh.ARRAY_TEX_UV] = uvs
	
	var mesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface_array)
	
	return mesh

func create_ray_visualizer():
	# Create a line to visualize the raycast
	ray_visualizer = MeshInstance3D.new()
	var immediate_mesh = ImmediateMesh.new()
	ray_visualizer.mesh = immediate_mesh
	
	var material = StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(1.0, 0.0, 0.0, 0.8)  # Red
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS
	ray_visualizer.material_override = material
	
	add_child(ray_visualizer)
	
	if Engine.is_editor_hint():
		ray_visualizer.owner = get_tree().edited_scene_root

func create_intersection_marker():
	# Create a small sphere to show exact intersection point
	intersection_marker = MeshInstance3D.new()
	var sphere_mesh = SphereMesh.new()
	sphere_mesh.radius = 0.1
	sphere_mesh.height = 0.2
	intersection_marker.mesh = sphere_mesh
	
	var material = StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(1.0, 0.0, 1.0, 1.0)  # Magenta
	material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS
	intersection_marker.material_override = material
	
	intersection_marker.visible = false
	add_child(intersection_marker)
	
	if Engine.is_editor_hint():
		intersection_marker.owner = get_tree().edited_scene_root

func update_cursor_position():
	if not camera or not ray_visualizer or not cursor_preview or not cursor_outline:
		return
	
	var viewport = get_viewport()
	if not viewport:
		cursor_preview.visible = false
		cursor_outline.visible = false
		return
	
	var mouse_pos = viewport.get_mouse_position()
	var from = camera.project_ray_origin(mouse_pos)
	var to = from + camera.project_ray_normal(mouse_pos) * 1000
	
	# Update ray visualizer
	var immediate_mesh = ImmediateMesh.new()
	ray_visualizer.mesh = immediate_mesh
	immediate_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	immediate_mesh.surface_add_vertex(from)
	immediate_mesh.surface_add_vertex(to)
	immediate_mesh.surface_end()
	
	# Create a plane at the current Y level
	var y_world = current_y_level * grid_size
	var placement_plane = Plane(Vector3.UP, y_world)
	var intersection = placement_plane.intersects_ray(from, to - from)
	
	if intersection:
		# Directly snap to grid without converting Y
		var grid_pos = Vector3i(
			floori(intersection.x / grid_size),
			current_y_level,
			floori(intersection.z / grid_size)
		)
		
		# Update outline for hovered cell
		update_cursor_outline(grid_pos)
		
		# Show preview at this position
		cursor_preview.visible = true
		cursor_preview.position = grid_to_world(grid_pos)
		
		# Change color based on whether tile exists
		var material = cursor_preview.material_override as StandardMaterial3D
		if material:
			if grid_pos in tiles:
				material.albedo_color = Color(1.0, 0.0, 0.0, 0.5)  # Red if occupied
			else:
				material.albedo_color = Color(0.0, 1.0, 0.0, 0.5)  # Green if empty
	else:
		cursor_preview.visible = false
		cursor_outline.visible = false

func create_grid_highlight():
	# Create a highlighted plane showing the current Y level
	grid_highlight = MeshInstance3D.new()
	var immediate_mesh = ImmediateMesh.new()
	grid_highlight.mesh = immediate_mesh
	
	add_child(grid_highlight)
	
	if Engine.is_editor_hint():
		grid_highlight.owner = get_tree().edited_scene_root
	
	update_grid_highlight()

func update_grid_highlight():
	if not grid_highlight:
		return
	
	var immediate_mesh = ImmediateMesh.new()
	grid_highlight.mesh = immediate_mesh
	
	# Create brighter material for current level
	var material = StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(0.3, 0.8, 0.3, 0.4)  # Green tint
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS
	grid_highlight.material_override = material
	
	# Use grid_size consistently
	var y = current_y_level * grid_size
	var start = -grid_range * grid_size
	var end = grid_range * grid_size
	
	immediate_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	
	# Draw highlighted grid at current Y level
	for i in range(-grid_range, grid_range + 1):
		var offset = i * grid_size
		
		# Lines parallel to X axis
		immediate_mesh.surface_add_vertex(Vector3(start, y, offset))
		immediate_mesh.surface_add_vertex(Vector3(end, y, offset))
		
		# Lines parallel to Z axis
		immediate_mesh.surface_add_vertex(Vector3(offset, y, start))
		immediate_mesh.surface_add_vertex(Vector3(offset, y, end))
	
	immediate_mesh.surface_end()

func _input(event):
	# Handle input in both editor and game mode
	if event is InputEventMouseButton and event.pressed:
		if Engine.is_editor_hint():
			mouse_pressed = true
			current_mouse_button = event
		else:
			mouse_pressed = true
			current_mouse_button = event
	elif event is InputEventMouseButton and event.is_released():
		mouse_pressed = false
		
	# Mouse motion for camera rotation (only in game mode)
	if event is InputEventMouseMotion and not Engine.is_editor_hint():
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE):
			camera_rotation.y -= event.relative.x * mouse_sensitivity
			camera_rotation.x -= event.relative.y * mouse_sensitivity
			camera_rotation.x = clamp(camera_rotation.x, -PI/2, PI/2)
	
	if event is InputEventMouse and not Engine.is_editor_hint():
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_WHEEL_DOWN):
			camera.fov = clamp(camera.fov + 1.0, 1.0, 179.0)
		elif Input.is_mouse_button_pressed(MOUSE_BUTTON_WHEEL_UP):
			camera.fov = clamp(camera.fov - 1.0, 1.0, 179.0)
	
	if Input.is_action_just_pressed("reset_fov"):
		camera.fov = 75.0
	
	# Tile selection keys
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_ENTER:
			get_viewport().debug_draw = Viewport.DEBUG_DRAW_WIREFRAME
		elif event.keycode == KEY_BACKSPACE:
			get_viewport().debug_draw = Viewport.DEBUG_DRAW_DISABLED
		if event.keycode == KEY_1:
			current_tile_type = 0
			print("Selected: Floor tile (gray)")
		elif event.keycode == KEY_2:
			current_tile_type = 1
			print("Selected: Wall tile (brown)")
		elif event.keycode == KEY_BRACKETLEFT or event.keycode == KEY_MINUS:
			current_y_level -= 1
			print("Y-Level: ", current_y_level)
			update_grid_highlight()
			update_grid_lines()
		elif event.keycode == KEY_BRACKETRIGHT or event.keycode == KEY_EQUAL:
			current_y_level += 1
			print("Y-Level: ", current_y_level)
			update_grid_highlight()
			update_grid_lines()

func handle_editor_input():
	# This runs every frame when mouse is held in editor
	var viewport = get_viewport()
	if not viewport:
		return
	
	var mouse_pos = viewport.get_mouse_position()
	if camera:
		attempt_tile_placement(mouse_pos, false)

func handle_mouse_click_editor(event: InputEventMouseButton):
	if camera and event.button_index == MOUSE_BUTTON_LEFT:
		attempt_tile_placement(event.position, true)
	elif camera and event.button_index == MOUSE_BUTTON_RIGHT:
		attempt_tile_removal(event.position)

func handle_mouse_click(event: InputEventMouseButton):
	if not camera:
		return
		
	if event.button_index == MOUSE_BUTTON_LEFT:
		attempt_tile_placement(event.position, true)
	elif event.button_index == MOUSE_BUTTON_RIGHT:
		attempt_tile_removal(event.position)

func attempt_tile_placement(mouse_pos: Vector2, single_click: bool):
	var from = camera.project_ray_origin(mouse_pos)
	var to = from + camera.project_ray_normal(mouse_pos) * 1000
	
	# Create a plane at the current Y level
	var y_world = current_y_level * grid_size
	var placement_plane = Plane(Vector3.UP, y_world)
	
	var ray_dir = (to - from).normalized()
	var intersection = placement_plane.intersects_ray(from, ray_dir)
	
	if intersection:
		# Snap intersection to grid, but keep Y at exact level
		var grid_pos = Vector3i(
			floori(intersection.x / grid_size),
			current_y_level,  # Don't convert Y, use level directly
			floori(intersection.z / grid_size)
		)
		
		# In editor mode with mouse held, only place if tile doesn't exist
		if not single_click and grid_pos in tiles:
			return
		
		place_tile(grid_pos, current_tile_type)

func attempt_tile_removal(mouse_pos: Vector2):
	if not camera:
		return
	
	var from = camera.project_ray_origin(mouse_pos)
	var to = from + camera.project_ray_normal(mouse_pos) * 1000
	
	# First try plane intersection at current Y level
	var y_world = current_y_level * grid_size
	var placement_plane = Plane(Vector3.UP, y_world)
	
	var ray_dir = (to - from).normalized()
	var intersection = placement_plane.intersects_ray(from, ray_dir)
	
	if intersection:
		# Snap intersection to grid, but keep Y at exact level
		var grid_pos = Vector3i(
			floori(intersection.x / grid_size),
			current_y_level,  # Don't convert Y, use level directly
			floori(intersection.z / grid_size)
		)
		if grid_pos in tiles:
			remove_tile(grid_pos)

func handle_camera_movement(delta):
	var speed = 5.0
	var input = Vector3.ZERO
	
	if Input.is_key_pressed(KEY_W): input.z -= 1
	if Input.is_key_pressed(KEY_S): input.z += 1
	if Input.is_key_pressed(KEY_A): input.x -= 1
	if Input.is_key_pressed(KEY_D): input.x += 1
	if Input.is_key_pressed(KEY_Q): input.y -= 1
	if Input.is_key_pressed(KEY_E): input.y += 1
	
	# Move relative to camera direction
	var direction = (camera.global_transform.basis * input).normalized()
	camera.global_translate(direction * speed * delta)

func handle_camera_rotation():
	# Apply rotation to camera
	camera.rotation.y = camera_rotation.y
	camera.rotation.x = camera_rotation.x

func world_to_grid(pos: Vector3) -> Vector3i:
	# Floor division to get the grid cell that contains this world position
	# For block placement, we want the cell the point is IN, not nearest to
	return Vector3i(
		floori(pos.x / grid_size),
		floori(pos.y / grid_size),
		floori(pos.z / grid_size)
	)

func grid_to_world(pos: Vector3i) -> Vector3:
	return Vector3(pos) * grid_size

func place_tile(pos: Vector3i, tile_type: int):
	tiles[pos] = tile_type
	
	# Update this tile and all neighbors
	update_tile_mesh(pos)
	for offset in [
		Vector3i(1,0,0), Vector3i(-1,0,0),
		Vector3i(0,1,0), Vector3i(0,-1,0),
		Vector3i(0,0,1), Vector3i(0,0,-1)
	]:
		var neighbor_pos = pos + offset
		if neighbor_pos in tiles:
			update_tile_mesh(neighbor_pos)

func remove_tile(pos: Vector3i):
	if pos not in tiles:
		return
	
	tiles.erase(pos)
	
	# Remove mesh instance
	if pos in tile_meshes:
		tile_meshes[pos].queue_free()
		tile_meshes.erase(pos)
	
	# Update neighbors
	for offset in [
		Vector3i(1,0,0), Vector3i(-1,0,0),
		Vector3i(0,1,0), Vector3i(0,-1,0),
		Vector3i(0,0,1), Vector3i(0,0,-1)
	]:
		var neighbor_pos = pos + offset
		if neighbor_pos in tiles:
			update_tile_mesh(neighbor_pos)

func update_tile_mesh(pos: Vector3i):
	var tile_type = tiles[pos]
	var neighbors = get_neighbors(pos)
	
	# Generate mesh based on type and neighbors
	var mesh = generate_tile_mesh(tile_type, neighbors)
	
	# Update or create MeshInstance3D
	if pos in tile_meshes:
		tile_meshes[pos].mesh = mesh
	else:
		var mesh_instance = MeshInstance3D.new()
		mesh_instance.mesh = mesh
		mesh_instance.position = grid_to_world(pos)
		mesh_instance.process_priority = 1  # Higher priority for placed tiles
		
		# Add collision
		var static_body = StaticBody3D.new()
		var collision_shape = CollisionShape3D.new()
		var box_shape = BoxShape3D.new()
		box_shape.size = Vector3(grid_size, grid_size, grid_size)
		collision_shape.shape = box_shape
		collision_shape.position = Vector3(grid_size/2, grid_size/2, grid_size/2)
		static_body.add_child(collision_shape)
		mesh_instance.add_child(static_body)
		
		add_child(mesh_instance)
		
		
		tile_meshes[pos] = mesh_instance

func get_neighbors(pos: Vector3i) -> Dictionary:
	var neighbors = {}
	var directions = {
		"north": Vector3i(0, 0, -1),
		"south": Vector3i(0, 0, 1),
		"east": Vector3i(1, 0, 0),
		"west": Vector3i(-1, 0, 0),
		"up": Vector3i(0, 1, 0),
		"down": Vector3i(0, -1, 0)
	}
	
	for dir_name in directions:
		var neighbor_pos = pos + directions[dir_name]
		neighbors[dir_name] = tiles.get(neighbor_pos, -1)
	
	return neighbors

func generate_tile_mesh(tile_type: int, neighbors: Dictionary) -> ArrayMesh:
	var surface_array = []
	surface_array.resize(Mesh.ARRAY_MAX)
	
	var verts = PackedVector3Array()
	var indices = PackedInt32Array()
	var normals = PackedVector3Array()
	var uvs = PackedVector2Array()
	
	var s = grid_size
	
	# Only render faces that don't have neighbors
	if neighbors["north"] == -1:
		add_quad(verts, indices, normals, uvs,
			Vector3(0, 0, 0), Vector3(s, 0, 0),
			Vector3(s, s, 0), Vector3(0, s, 0),
			Vector3(0, 0, -1))
	
	if neighbors["south"] == -1:
		add_quad(verts, indices, normals, uvs,
			Vector3(s, 0, s), Vector3(0, 0, s),
			Vector3(0, s, s), Vector3(s, s, s),
			Vector3(0, 0, 1))
	
	if neighbors["east"] == -1:
		add_quad(verts, indices, normals, uvs,
			Vector3(s, 0, 0), Vector3(s, 0, s),
			Vector3(s, s, s), Vector3(s, s, 0),
			Vector3(1, 0, 0))
	
	if neighbors["west"] == -1:
		add_quad(verts, indices, normals, uvs,
			Vector3(0, 0, s), Vector3(0, 0, 0),
			Vector3(0, s, 0), Vector3(0, s, s),
			Vector3(-1, 0, 0))
	
	if neighbors["up"] == -1:
		add_quad(verts, indices, normals, uvs,
			Vector3(0, s, 0), Vector3(s, s, 0),
			Vector3(s, s, s), Vector3(0, s, s),
			Vector3(0, 1, 0))
	
	"""	if neighbors["down"] == -1:
		add_quad(verts, indices, normals, uvs,
			Vector3(0, 0, s), Vector3(s, 0, s),
			Vector3(s, 0, 0), Vector3(0, 0, 0),
			Vector3(0, -1, 0))"""
	
	surface_array[Mesh.ARRAY_VERTEX] = verts
	surface_array[Mesh.ARRAY_INDEX] = indices
	surface_array[Mesh.ARRAY_NORMAL] = normals
	surface_array[Mesh.ARRAY_TEX_UV] = uvs
	
	var mesh = ArrayMesh.new()
	if verts.size() > 0:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface_array)
		
		# Add material based on tile type
		var material = StandardMaterial3D.new()
		if tile_type == 0:
			material.albedo_color = Color(0.7, 0.7, 0.7)  # Floor - gray
		elif tile_type == 1:
			material.albedo_color = Color(0.8, 0.5, 0.3)  # Wall - brown
		mesh.surface_set_material(0, material)
	
	return mesh

func add_quad(verts: PackedVector3Array, indices: PackedInt32Array,
			  normals: PackedVector3Array, uvs: PackedVector2Array,
			  v1: Vector3, v2: Vector3, v3: Vector3, v4: Vector3, normal: Vector3):
	var start = verts.size()
	
	verts.append_array([v1, v2, v3, v4])
	normals.append_array([normal, normal, normal, normal])
	uvs.append_array([
		Vector2(0, 1), Vector2(1, 1),
		Vector2(1, 0), Vector2(0, 0)
	])
	
	indices.append_array([
		start, start + 1, start + 2,
		start, start + 2, start + 3
	])
