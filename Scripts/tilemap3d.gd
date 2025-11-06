class_name TileMap3D extends RefCounted

var tiles = {}  # Vector3i -> tile_type
var tile_meshes = {}  # Vector3i -> MeshInstance3D
var custom_meshes = {}  # tile_type -> ArrayMesh (custom loaded meshes)
var grid_size: float = 1.0
var parent_node: Node3D
var offset_provider: Callable

var custom_materials: Dictionary = {}  # tile_type -> Material


func _init(grid_sz: float = 1.0):
	grid_size = grid_sz


func set_parent(node: Node3D):
	parent_node = node


func set_offset_provider(provider: Callable):
	offset_provider = provider


func get_offset_for_y(y_level: int) -> Vector2:
	if offset_provider.is_valid():
		return offset_provider.call(y_level)
	return Vector2.ZERO


# Load an OBJ file and associate it with a tile type (supports multiple materials via usemtl groups)
func load_obj_for_tile_type(tile_type: int, obj_path: String) -> bool:
	var file = FileAccess.open(obj_path, FileAccess.READ)
	if not file:
		push_error("Failed to open OBJ file: " + obj_path)
		return false
	
	var temp_vertices = []
	var temp_normals = []
	var temp_uvs = []
	var material_groups = {}  # material_name -> faces
	var current_material = "default"
	
	while not file.eof_reached():
		var line = file.get_line().strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		
		var parts = line.split(" ", false)
		if parts.size() == 0:
			continue
		
		match parts[0]:
			"v":  # Vertex
				if parts.size() >= 4:
					temp_vertices.append(Vector3(
						parts[1].to_float(),
						parts[2].to_float(),
						parts[3].to_float()
					))
			"vn":  # Normal
				if parts.size() >= 4:
					temp_normals.append(Vector3(
						parts[1].to_float(),
						parts[2].to_float(),
						parts[3].to_float()
					))
			"vt":  # UV
				if parts.size() >= 3:
					temp_uvs.append(Vector2(
						parts[1].to_float(),
						parts[2].to_float()
					))
			"usemtl":  # Material assignment
				if parts.size() >= 2:
					current_material = parts[1]
					if current_material not in material_groups:
						material_groups[current_material] = []
			"f":  # Face
				var face = []
				for i in range(1, parts.size()):
					var indices = parts[i].split("/")
					var vert_idx = indices[0].to_int() - 1
					var uv_idx = indices[1].to_int() - 1 if indices.size() > 1 and indices[1] != "" else -1
					var norm_idx = indices[2].to_int() - 1 if indices.size() > 2 else -1
					face.append({"v": vert_idx, "vt": uv_idx, "vn": norm_idx})
				
				# Add face to current material group
				if current_material not in material_groups:
					material_groups[current_material] = []
				material_groups[current_material].append(face)
	
	file.close()
	
	# Create mesh with multiple surfaces (one per material)
	var mesh = ArrayMesh.new()
	var materials_array = []
	
	print("Loading mesh with ", material_groups.size(), " material groups: ", material_groups.keys())
	
	for mat_name in material_groups:
		var faces = material_groups[mat_name]
		
		# Convert faces to triangles
		var final_verts = PackedVector3Array()
		var final_normals = PackedVector3Array()
		var final_uvs = PackedVector2Array()
		var final_indices = PackedInt32Array()
		
		for face in faces:
			# Triangulate face (simple fan triangulation)
			for i in range(1, face.size() - 1):
				for idx in [0, i, i + 1]:
					var face_vert = face[idx]
					final_verts.append(temp_vertices[face_vert.v])
					
					if face_vert.vn >= 0 and face_vert.vn < temp_normals.size():
						final_normals.append(temp_normals[face_vert.vn])
					else:
						final_normals.append(Vector3.UP)
					
					if face_vert.vt >= 0 and face_vert.vt < temp_uvs.size():
						final_uvs.append(temp_uvs[face_vert.vt])
					else:
						final_uvs.append(Vector2.ZERO)
		
		# Create indices
		for i in range(final_verts.size()):
			final_indices.append(i)
		
		# Create surface for this material group
		var surface_array = []
		surface_array.resize(Mesh.ARRAY_MAX)
		surface_array[Mesh.ARRAY_VERTEX] = final_verts
		surface_array[Mesh.ARRAY_NORMAL] = final_normals
		surface_array[Mesh.ARRAY_TEX_UV] = final_uvs
		surface_array[Mesh.ARRAY_INDEX] = final_indices
		
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface_array)
		
		# Create default material for this surface
		var material = StandardMaterial3D.new()
		material.albedo_color = Color.WHITE
		material.cull_mode = BaseMaterial3D.CULL_BACK
		mesh.surface_set_material(mesh.get_surface_count() - 1, material)
		materials_array.append(material)
		
		print("  Surface ", mesh.get_surface_count() - 1, ": ", mat_name, " (", faces.size(), " faces)")
	
	custom_meshes[tile_type] = mesh
	custom_materials[tile_type] = materials_array  # Store array of materials
	
	print("✓ Loaded mesh for tile type ", tile_type, " with ", mesh.get_surface_count(), " surfaces")
	
	# Fix Blender's inverted normals and winding order (handles multiple surfaces)
	flip_mesh_normals(tile_type)
	
	# Auto-position and scale the mesh to fit grid (handles multiple surfaces)
	align_mesh_to_grid(tile_type)
	
	return true


# Extend boundary vertices to grid edges (fixes gaps from bevels)
func extend_mesh_to_boundaries(tile_type: int, threshold: float = 0.15) -> bool:
	var mesh_data = get_mesh_data(tile_type)
	if mesh_data.is_empty():
		return false
	
	var vertices = mesh_data.vertices
	var s = grid_size
	
	for i in range(vertices.size()):
		var v = vertices[i]
		
		# Snap vertices close to boundaries to exact boundaries
		if v.x < threshold:
			v.x = 0
		elif v.x > s - threshold:
			v.x = s
			
		if v.y < threshold:
			v.y = -0.5
		elif v.y > s - threshold:
			v.y = s
			
		if v.z < threshold:
			v.z = 0
		elif v.z > s - threshold:
			v.z = s
		
		vertices[i] = v
	
	return edit_mesh_vertices(tile_type, vertices)


# Flip normals and reverse winding order for Blender meshes (handles multiple surfaces)
func flip_mesh_normals(tile_type: int) -> bool:
	if tile_type not in custom_meshes:
		return false
	
	var mesh = custom_meshes[tile_type]
	var new_mesh = ArrayMesh.new()
	
	# Process each surface
	for surface_idx in range(mesh.get_surface_count()):
		var arrays = mesh.surface_get_arrays(surface_idx)
		var vertices = arrays[Mesh.ARRAY_VERTEX]
		var normals = arrays[Mesh.ARRAY_NORMAL]
		var uvs = arrays[Mesh.ARRAY_TEX_UV]
		var indices = arrays[Mesh.ARRAY_INDEX]
		
		# Flip normals
		for i in range(normals.size()):
			normals[i] = -normals[i]
		
		# Reverse winding order (swap every triangle's last two vertices)
		for i in range(0, indices.size(), 3):
			var temp = indices[i + 1]
			indices[i + 1] = indices[i + 2]
			indices[i + 2] = temp
		
		# Create new surface
		var surface_array = []
		surface_array.resize(Mesh.ARRAY_MAX)
		surface_array[Mesh.ARRAY_VERTEX] = vertices
		surface_array[Mesh.ARRAY_NORMAL] = normals
		surface_array[Mesh.ARRAY_TEX_UV] = uvs
		surface_array[Mesh.ARRAY_INDEX] = indices
		
		new_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface_array)
		new_mesh.surface_set_material(surface_idx, mesh.surface_get_material(surface_idx))
	
	custom_meshes[tile_type] = new_mesh
	return true


# Align mesh to grid cell (bottom-left corner at origin) - handles multiple surfaces
func align_mesh_to_grid(tile_type: int) -> bool:
	if tile_type not in custom_meshes:
		return false
	
	var mesh = custom_meshes[tile_type]
	
	# Calculate bounding box across ALL surfaces
	var min_bounds = Vector3.ZERO
	var max_bounds = Vector3.ZERO
	var first_vertex = true
	
	for surface_idx in range(mesh.get_surface_count()):
		var arrays = mesh.surface_get_arrays(surface_idx)
		var vertices = arrays[Mesh.ARRAY_VERTEX]
		
		for v in vertices:
			if first_vertex:
				min_bounds = v
				max_bounds = v
				first_vertex = false
			else:
				min_bounds.x = min(min_bounds.x, v.x)
				min_bounds.y = min(min_bounds.y, v.y)
				min_bounds.z = min(min_bounds.z, v.z)
				max_bounds.x = max(max_bounds.x, v.x)
				max_bounds.y = max(max_bounds.y, v.y)
				max_bounds.z = max(max_bounds.z, v.z)
	
	var size = max_bounds - min_bounds
	
	# Calculate scale to fit within grid_size
	var max_dimension = max(size.x, max(size.y, size.z))
	var scale_factor = grid_size / max_dimension if max_dimension > 0 else 1.0
	
	# Transform all surfaces
	var new_mesh = ArrayMesh.new()
	
	for surface_idx in range(mesh.get_surface_count()):
		var arrays = mesh.surface_get_arrays(surface_idx)
		var vertices = arrays[Mesh.ARRAY_VERTEX].duplicate()
		
		# Transform vertices
		for i in range(vertices.size()):
			vertices[i] = (vertices[i] - min_bounds) * scale_factor
		
		# Create new surface
		var surface_array = []
		surface_array.resize(Mesh.ARRAY_MAX)
		surface_array[Mesh.ARRAY_VERTEX] = vertices
		surface_array[Mesh.ARRAY_NORMAL] = arrays[Mesh.ARRAY_NORMAL]
		surface_array[Mesh.ARRAY_TEX_UV] = arrays[Mesh.ARRAY_TEX_UV]
		surface_array[Mesh.ARRAY_INDEX] = arrays[Mesh.ARRAY_INDEX]
		
		new_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface_array)
		new_mesh.surface_set_material(surface_idx, mesh.surface_get_material(surface_idx))
	
	custom_meshes[tile_type] = new_mesh
	return true


# Get editable mesh data for a tile type (returns first surface)
func get_mesh_data(tile_type: int) -> Dictionary:
	var mesh = custom_meshes.get(tile_type)
	if not mesh or mesh.get_surface_count() == 0:
		return {}
	
	var arrays = mesh.surface_get_arrays(0)
	return {
		"vertices": arrays[Mesh.ARRAY_VERTEX],
		"normals": arrays[Mesh.ARRAY_NORMAL],
		"uvs": arrays[Mesh.ARRAY_TEX_UV],
		"indices": arrays[Mesh.ARRAY_INDEX]
	}


# Edit vertices of a custom mesh (updates all surfaces proportionally)
func edit_mesh_vertices(tile_type: int, new_vertices: PackedVector3Array) -> bool:
	if tile_type not in custom_meshes:
		push_error("No custom mesh for tile type: " + str(tile_type))
		return false
	
	var mesh = custom_meshes[tile_type]
	if mesh.get_surface_count() == 0:
		return false
	
	var arrays = mesh.surface_get_arrays(0)
	
	if new_vertices.size() != arrays[Mesh.ARRAY_VERTEX].size():
		push_error("New vertices array size doesn't match original")
		return false
	
	# Rebuild mesh with updated vertices for first surface
	var new_mesh = ArrayMesh.new()
	
	# Update first surface with new vertices
	var surface_array = []
	surface_array.resize(Mesh.ARRAY_MAX)
	surface_array[Mesh.ARRAY_VERTEX] = new_vertices
	surface_array[Mesh.ARRAY_NORMAL] = arrays[Mesh.ARRAY_NORMAL]
	surface_array[Mesh.ARRAY_TEX_UV] = arrays[Mesh.ARRAY_TEX_UV]
	surface_array[Mesh.ARRAY_INDEX] = arrays[Mesh.ARRAY_INDEX]
	
	new_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface_array)
	new_mesh.surface_set_material(0, mesh.surface_get_material(0))
	
	# Copy other surfaces unchanged
	for surface_idx in range(1, mesh.get_surface_count()):
		var other_arrays = mesh.surface_get_arrays(surface_idx)
		var other_surface_array = []
		other_surface_array.resize(Mesh.ARRAY_MAX)
		other_surface_array[Mesh.ARRAY_VERTEX] = other_arrays[Mesh.ARRAY_VERTEX]
		other_surface_array[Mesh.ARRAY_NORMAL] = other_arrays[Mesh.ARRAY_NORMAL]
		other_surface_array[Mesh.ARRAY_TEX_UV] = other_arrays[Mesh.ARRAY_TEX_UV]
		other_surface_array[Mesh.ARRAY_INDEX] = other_arrays[Mesh.ARRAY_INDEX]
		
		new_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, other_surface_array)
		new_mesh.surface_set_material(surface_idx, mesh.surface_get_material(surface_idx))
	
	custom_meshes[tile_type] = new_mesh
	
	# Update all tiles using this mesh
	for pos in tiles:
		if tiles[pos] == tile_type:
			update_tile_mesh(pos)
	
	return true


# Transform a single vertex by index
func transform_vertex(tile_type: int, vertex_index: int, new_position: Vector3) -> bool:
	var mesh_data = get_mesh_data(tile_type)
	if mesh_data.is_empty():
		return false
	
	var vertices = mesh_data.vertices.duplicate()
	if vertex_index < 0 or vertex_index >= vertices.size():
		push_error("Vertex index out of range")
		return false
	
	vertices[vertex_index] = new_position
	return edit_mesh_vertices(tile_type, vertices)

# Scale entire mesh
func scale_mesh(tile_type: int, scale: Vector3) -> bool:
	var mesh_data = get_mesh_data(tile_type)
	if mesh_data.is_empty():
		return false
	
	var vertices = mesh_data.vertices.duplicate()
	for i in range(vertices.size()):
		vertices[i] *= scale
	
	return edit_mesh_vertices(tile_type, vertices)


# Recalculate normals for a mesh (handles all surfaces)
func recalculate_normals(tile_type: int) -> bool:
	if tile_type not in custom_meshes:
		return false
	
	var mesh = custom_meshes[tile_type]
	var new_mesh = ArrayMesh.new()
	
	for surface_idx in range(mesh.get_surface_count()):
		var arrays = mesh.surface_get_arrays(surface_idx)
		var vertices = arrays[Mesh.ARRAY_VERTEX]
		var indices = arrays[Mesh.ARRAY_INDEX]
		
		var normals = PackedVector3Array()
		normals.resize(vertices.size())
		for i in range(normals.size()):
			normals[i] = Vector3.ZERO
		
		# Calculate face normals and accumulate
		for i in range(0, indices.size(), 3):
			var i0 = indices[i]
			var i1 = indices[i + 1]
			var i2 = indices[i + 2]
			
			var v0 = vertices[i0]
			var v1 = vertices[i1]
			var v2 = vertices[i2]
			
			var edge1 = v1 - v0
			var edge2 = v2 - v0
			var normal = edge1.cross(edge2).normalized()
			
			normals[i0] += normal
			normals[i1] += normal
			normals[i2] += normal
		
		# Normalize
		for i in range(normals.size()):
			normals[i] = normals[i].normalized()
		
		# Update mesh
		var surface_array = []
		surface_array.resize(Mesh.ARRAY_MAX)
		surface_array[Mesh.ARRAY_VERTEX] = vertices
		surface_array[Mesh.ARRAY_NORMAL] = normals
		surface_array[Mesh.ARRAY_TEX_UV] = arrays[Mesh.ARRAY_TEX_UV]
		surface_array[Mesh.ARRAY_INDEX] = indices
		
		new_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface_array)
		new_mesh.surface_set_material(surface_idx, mesh.surface_get_material(surface_idx))
	
	custom_meshes[tile_type] = new_mesh
	
	# Update all tiles
	for pos in tiles:
		if tiles[pos] == tile_type:
			update_tile_mesh(pos)
	
	return true


func world_to_grid(pos: Vector3) -> Vector3i:
	return Vector3i(
		floori(pos.x / grid_size),
		floori(pos.y / grid_size),
		floori(pos.z / grid_size)
	)


func grid_to_world(pos: Vector3i) -> Vector3:
	var offset = get_offset_for_y(pos.y)
	return Vector3(pos.x * grid_size + offset.x, pos.y * grid_size, pos.z * grid_size + offset.y)

func place_tile(pos: Vector3i, tile_type: int):
	tiles[pos] = tile_type
	
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
	
	if pos in tile_meshes:
		tile_meshes[pos].queue_free()
		tile_meshes.erase(pos)
	
	for offset in [
		Vector3i(1,0,0), Vector3i(-1,0,0),
		Vector3i(0,1,0), Vector3i(0,-1,0),
		Vector3i(0,0,1), Vector3i(0,0,-1)
	]:
		var neighbor_pos = pos + offset
		if neighbor_pos in tiles:
			update_tile_mesh(neighbor_pos)

func has_tile(pos: Vector3i) -> bool:
	return pos in tiles

func get_tile_type(pos: Vector3i) -> int:
	return tiles.get(pos, -1)

func refresh_y_level(y_level: int):
	for pos in tiles.keys():
		if pos.y == y_level:
			update_tile_mesh(pos)
	for pos in tiles.keys():
		if pos.y == y_level + 1 or pos.y == y_level - 1:
			update_tile_mesh(pos)


func update_tile_mesh(pos: Vector3i):
	if not parent_node:
		return
	
	var tile_type = tiles[pos]
	
	# Use custom mesh if available, otherwise generate default
	var mesh: ArrayMesh
	if tile_type in custom_meshes:
		var neighbors = get_neighbors(pos)
		mesh = generate_custom_tile_mesh(pos, tile_type, neighbors)
	else:
		var neighbors = get_neighbors(pos)
		mesh = generate_tile_mesh(pos, tile_type, neighbors)
	
	if pos in tile_meshes:
		tile_meshes[pos].mesh = mesh
		tile_meshes[pos].position = grid_to_world(pos)
	else:
		var mesh_instance = MeshInstance3D.new()
		mesh_instance.mesh = mesh
		mesh_instance.position = grid_to_world(pos)
		mesh_instance.process_priority = 1
		
		var static_body = StaticBody3D.new()
		var collision_shape = CollisionShape3D.new()
		var box_shape = BoxShape3D.new()
		box_shape.size = Vector3(grid_size, grid_size, grid_size)
		collision_shape.shape = box_shape
		collision_shape.position = Vector3(grid_size/2, grid_size/2, grid_size/2)
		static_body.add_child(collision_shape)
		mesh_instance.add_child(static_body)
		
		parent_node.add_child(mesh_instance)
		tile_meshes[pos] = mesh_instance


# Generate mesh for custom tile types with neighbor culling and conditional boundary extension
func generate_custom_tile_mesh(pos: Vector3i, tile_type: int, neighbors: Dictionary) -> ArrayMesh:
	if tile_type not in custom_meshes:
		return ArrayMesh.new()
	
	var base_mesh = custom_meshes[tile_type]
	var arrays = base_mesh.surface_get_arrays(0)
	var vertices = arrays[Mesh.ARRAY_VERTEX]
	var normals = arrays[Mesh.ARRAY_NORMAL]
	var uvs = arrays[Mesh.ARRAY_TEX_UV]
	var indices = arrays[Mesh.ARRAY_INDEX]
	
	# Build new arrays with culled/flattened faces
	var new_verts = PackedVector3Array()
	var new_normals = PackedVector3Array()
	var new_uvs = PackedVector2Array()
	var new_indices = PackedInt32Array()
	
	var s = grid_size
	var boundary_threshold = 0.02
	var extend_threshold = 0.35  # Threshold for extending vertices to boundaries
	
	# Process each triangle
	for i in range(0, indices.size(), 3):
		var i0 = indices[i]
		var i1 = indices[i + 1]
		var i2 = indices[i + 2]
		
		var v0 = vertices[i0]
		var v1 = vertices[i1]
		var v2 = vertices[i2]
		
		# Get face normal
		var face_normal = (normals[i0] + normals[i1] + normals[i2]).normalized()
		
		# Check if ALL vertices of this face are on a boundary
		var all_on_x_min = v0.x < boundary_threshold and v1.x < boundary_threshold and v2.x < boundary_threshold
		var all_on_x_max = v0.x > s - boundary_threshold and v1.x > s - boundary_threshold and v2.x > s - boundary_threshold
		var all_on_y_min = v0.y < boundary_threshold and v1.y < boundary_threshold and v2.y < boundary_threshold
		var all_on_y_max = v0.y > s - boundary_threshold and v1.y > s - boundary_threshold and v2.y > s - boundary_threshold
		var all_on_z_min = v0.z < boundary_threshold and v1.z < boundary_threshold and v2.z < boundary_threshold
		var all_on_z_max = v0.z > s - boundary_threshold and v1.z > s - boundary_threshold and v2.z > s - boundary_threshold
		
		var should_cull = false
		
		# Check each boundary direction
		if all_on_x_min and face_normal.x < -0.3 and neighbors["west"] != -1:
			if not should_render_vertical_face(pos, pos + Vector3i(-1, 0, 0)):
				should_cull = true
		elif all_on_x_max and face_normal.x > 0.3 and neighbors["east"] != -1:
			if not should_render_vertical_face(pos, pos + Vector3i(1, 0, 0)):
				should_cull = true
		elif all_on_y_min and face_normal.y < -0.3 and neighbors["down"] != -1:
			if not should_render_vertical_face(pos, pos + Vector3i(0, -1, 0)):
				should_cull = true
		elif all_on_y_max and face_normal.y > 0.3 and neighbors["up"] != -1:
			if not should_render_vertical_face(pos, pos + Vector3i(0, 1, 0)):
				should_cull = true
		elif all_on_z_min and face_normal.z < -0.3 and neighbors["north"] != -1:
			if not should_render_vertical_face(pos, pos + Vector3i(0, 0, -1)):
				should_cull = true
		elif all_on_z_max and face_normal.z > 0.3 and neighbors["south"] != -1:
			if not should_render_vertical_face(pos, pos + Vector3i(0, 0, 1)):
				should_cull = true
		
		if should_cull:
			continue
		
		# Extend vertices to boundaries only if there's a neighboring tile
		# This fixes gaps from bevels when tiles are adjacent
		v0 = extend_vertex_to_boundary_if_neighbor(v0, neighbors, extend_threshold, pos)
		v1 = extend_vertex_to_boundary_if_neighbor(v1, neighbors, extend_threshold, pos)
		v2 = extend_vertex_to_boundary_if_neighbor(v2, neighbors, extend_threshold, pos)
		
		# Add this triangle
		var start_idx = new_verts.size()
		new_verts.append(v0)
		new_verts.append(v1)
		new_verts.append(v2)
		
		new_normals.append(normals[i0])
		new_normals.append(normals[i1])
		new_normals.append(normals[i2])
		
		if uvs.size() > 0:
			new_uvs.append(uvs[i0] if i0 < uvs.size() else Vector2.ZERO)
			new_uvs.append(uvs[i1] if i1 < uvs.size() else Vector2.ZERO)
			new_uvs.append(uvs[i2] if i2 < uvs.size() else Vector2.ZERO)
		
		new_indices.append(start_idx)
		new_indices.append(start_idx + 1)
		new_indices.append(start_idx + 2)
	
	# Create new mesh
	var surface_array = []
	surface_array.resize(Mesh.ARRAY_MAX)
	surface_array[Mesh.ARRAY_VERTEX] = new_verts
	surface_array[Mesh.ARRAY_NORMAL] = new_normals
	if new_uvs.size() > 0:
		surface_array[Mesh.ARRAY_TEX_UV] = new_uvs
	surface_array[Mesh.ARRAY_INDEX] = new_indices
	
	var mesh = ArrayMesh.new()
	if new_verts.size() > 0:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface_array)
		# Apply all materials from base mesh
		for surface_idx in range(base_mesh.get_surface_count()):
			var mat = base_mesh.surface_get_material(surface_idx)
			if mat:
				mesh.surface_set_material(0, mat)
				break  # Use first available material for the combined surface
	
	return mesh


# Helper function to extend a vertex to boundary only if there's a neighbor in that direction
# For corner vertices, only extend on axes where neighbors exist
func extend_vertex_to_boundary_if_neighbor(v: Vector3, neighbors: Dictionary, threshold: float, pos: Vector3i) -> Vector3:
	var result = v
	
	# Determine which boundaries this vertex is near
	var near_x_min = v.x < threshold
	var near_x_max = v.x > grid_size - threshold
	#var near_y_min = v.y < threshold
	var near_y_max = v.y > grid_size - threshold
	var near_z_min = v.z < threshold
	var near_z_max = v.z > grid_size - threshold
	
	# Special case: if there's a block above, remove ALL bevels on the entire block
	# This makes the block underneath a complete flat box
	if neighbors["up"] != -1:
		var current_offset = get_offset_for_y(pos.y)
		var neighbor_offset = get_offset_for_y(pos.y + 1)
		
		# Only flatten if offsets match (blocks are aligned)
		if current_offset.is_equal_approx(neighbor_offset):
			# Extend X-axis to boundaries
			if v.x < grid_size * 0.5:
				result.x = 0
			else:
				result.x = grid_size
			
			# Extend Y-axis to boundaries
			if v.y < grid_size * 0.5:
				result.y = 0
			else:
				result.y = grid_size
			
			# Extend Z-axis to boundaries
			if v.z < grid_size * 0.5:
				result.z = 0
			else:
				result.z = grid_size
			
			# Return early - we've handled this vertex completely
			return result
	
	# If there's a tile below, extend ALL bottom bevel vertices down
	# Account for offset differences by extending extra
	var has_down_neighbor = neighbors["down"] != -1
	if has_down_neighbor and v.y < grid_size * 0.5:
		var current_offset = get_offset_for_y(pos.y)
		var neighbor_offset = get_offset_for_y(pos.y - 1)
		var offset_diff = current_offset - neighbor_offset
		
		# Calculate how much extra we need to extend based on Z-offset difference
		# The Z-offset creates a vertical gap that needs to be filled
		var extra_extension = abs(offset_diff.y)  # Z-offset affects vertical gap
		
		result.y = -extra_extension
	
	# For corner vertices, check if we should extend on each axis
	# A corner vertex (e.g., at x_min and z_min) should only extend on an axis
	# if there's a neighbor on that axis OR on both axes
	
	# X-axis extension
	if near_x_min:
		# Check if there's a neighbor to the west
		var has_west_neighbor = neighbors["west"] != -1
		# For corner cases, also check if extending would help connect to a diagonal neighbor
		if near_z_min and neighbors["north"] != -1 and not has_west_neighbor:
			# Don't extend x if we only have a north neighbor at the x-min, z-min corner
			pass
		elif near_z_max and neighbors["south"] != -1 and not has_west_neighbor:
			# Don't extend x if we only have a south neighbor at the x-min, z-max corner
			pass
		elif has_west_neighbor:
			result.x = 0
			
	elif near_x_max:
		var has_east_neighbor = neighbors["east"] != -1
		if near_z_min and neighbors["north"] != -1 and not has_east_neighbor:
			pass
		elif near_z_max and neighbors["south"] != -1 and not has_east_neighbor:
			pass
		elif has_east_neighbor:
			result.x = grid_size
	
	# Top face handling
	if near_y_max:
		var has_up_neighbor = neighbors["up"] != -1
		if near_x_min and neighbors["west"] != -1 and not has_up_neighbor:
			pass
		elif near_x_max and neighbors["east"] != -1 and not has_up_neighbor:
			pass
		elif near_z_min and neighbors["north"] != -1 and not has_up_neighbor:
			pass
		elif near_z_max and neighbors["south"] != -1 and not has_up_neighbor:
			pass
		elif has_up_neighbor:
			result.y = grid_size
	
	# Z-axis extension
	if near_z_min:
		var has_north_neighbor = neighbors["north"] != -1
		if near_x_min and neighbors["west"] != -1 and not has_north_neighbor:
			pass
		elif near_x_max and neighbors["east"] != -1 and not has_north_neighbor:
			pass
		elif has_north_neighbor:
			result.z = 0
			
	elif near_z_max:
		var has_south_neighbor = neighbors["south"] != -1
		if near_x_min and neighbors["west"] != -1 and not has_south_neighbor:
			pass
		elif near_x_max and neighbors["east"] != -1 and not has_south_neighbor:
			pass
		elif has_south_neighbor:
			result.z = grid_size
	
	return result


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

func should_render_vertical_face(current_pos: Vector3i, neighbor_pos: Vector3i) -> bool:
	if neighbor_pos not in tiles:
		return true
	
	var current_offset = get_offset_for_y(current_pos.y)
	var neighbor_offset = get_offset_for_y(neighbor_pos.y)
	
	if not current_offset.is_equal_approx(neighbor_offset):
		return true
	
	return false


func generate_tile_mesh(pos: Vector3i, tile_type: int, neighbors: Dictionary) -> ArrayMesh:
	var surface_array = []
	surface_array.resize(Mesh.ARRAY_MAX)
	
	var verts = PackedVector3Array()
	var indices = PackedInt32Array()
	var normals = PackedVector3Array()
	var uvs = PackedVector2Array()
	
	var s = grid_size
	
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
	
	if should_render_vertical_face(pos, pos + Vector3i(0, 1, 0)):
		add_quad(verts, indices, normals, uvs,
			Vector3(0, s, 0), Vector3(s, s, 0),
			Vector3(s, s, s), Vector3(0, s, s),
			Vector3(0, 1, 0))
	
	if should_render_vertical_face(pos, pos + Vector3i(0, -1, 0)):
		add_quad(verts, indices, normals, uvs,
			Vector3(0, 0, s), Vector3(s, 0, s),
			Vector3(s, 0, 0), Vector3(0, 0, 0),
			Vector3(0, -1, 0))
	
	surface_array[Mesh.ARRAY_VERTEX] = verts
	surface_array[Mesh.ARRAY_INDEX] = indices
	surface_array[Mesh.ARRAY_NORMAL] = normals
	surface_array[Mesh.ARRAY_TEX_UV] = uvs
	
	var mesh = ArrayMesh.new()
	if verts.size() > 0:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface_array)
		
		var material = StandardMaterial3D.new()
		if tile_type == 0:
			material.albedo_color = Color(0.7, 0.7, 0.7)
		elif tile_type == 1:
			material.albedo_color = Color(0.8, 0.5, 0.3)
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


func generate_optimized_level_mesh() -> ArrayMesh:
	"""Generate optimized mesh - handles both standard and custom tiles"""
	
	var all_verts = PackedVector3Array()
	var all_indices = PackedInt32Array()
	var all_normals = PackedVector3Array()
	var all_uvs = PackedVector2Array()
	var vertex_offset = 0
	
	# Group tiles by type for potential instancing optimization
	var tiles_by_type = {}
	for pos in tiles:
		var tile_type = tiles[pos]
		if tile_type not in tiles_by_type:
			tiles_by_type[tile_type] = []
		tiles_by_type[tile_type].append(pos)
	
	print("Optimizing ", tiles.size(), " tiles into single mesh...")
	print("Tile types found: ", tiles_by_type.keys())
	
	# Process each tile type
	for tile_type in tiles_by_type:
		var positions = tiles_by_type[tile_type]
		print("  Processing tile type ", tile_type, ": ", positions.size(), " instances")
		
		if tile_type in custom_meshes:
			# Custom mesh - bake each instance with neighbor culling
			for pos in positions:
				var neighbors = get_neighbors(pos)
				var tile_mesh = generate_custom_tile_mesh(pos, tile_type, neighbors)
				var world_pos = grid_to_world(pos)
				
				# Add this mesh instance to combined mesh
				vertex_offset = append_mesh_to_arrays(
					tile_mesh, world_pos,
					all_verts, all_indices, all_normals, all_uvs,
					vertex_offset
				)
		else:
			# Standard tiles - bake each with neighbor culling
			for pos in positions:
				var neighbors = get_neighbors(pos)
				var tile_mesh = generate_tile_mesh(pos, tile_type, neighbors)
				var world_pos = grid_to_world(pos)
				
				vertex_offset = append_mesh_to_arrays(
					tile_mesh, world_pos,
					all_verts, all_indices, all_normals, all_uvs,
					vertex_offset
				)
	
	# Create final combined mesh
	var surface_array = []
	surface_array.resize(Mesh.ARRAY_MAX)
	surface_array[Mesh.ARRAY_VERTEX] = all_verts
	surface_array[Mesh.ARRAY_INDEX] = all_indices
	surface_array[Mesh.ARRAY_NORMAL] = all_normals
	surface_array[Mesh.ARRAY_TEX_UV] = all_uvs
	
	var mesh = ArrayMesh.new()
	if all_verts.size() > 0:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface_array)
		
		# Add a default material
		var material = StandardMaterial3D.new()
		material.albedo_color = Color.WHITE
		mesh.surface_set_material(0, material)
	
	print("✓ Optimization complete!")
	print("  Total vertices: ", all_verts.size())
	print("  Total triangles: ", all_indices.size() / 3.0)
	
	return mesh


func append_mesh_to_arrays(mesh: ArrayMesh, world_pos: Vector3,
						   verts: PackedVector3Array, indices: PackedInt32Array,
						   normals: PackedVector3Array, uvs: PackedVector2Array,
						   vertex_offset: int) -> int:
	"""Append a mesh instance to the combined arrays"""
	
	if mesh.get_surface_count() == 0:
		return vertex_offset
	
	var arrays = mesh.surface_get_arrays(0)
	var mesh_verts = arrays[Mesh.ARRAY_VERTEX]
	var mesh_indices = arrays[Mesh.ARRAY_INDEX]
	var mesh_normals = arrays[Mesh.ARRAY_NORMAL]
	var mesh_uvs = arrays[Mesh.ARRAY_TEX_UV] if arrays[Mesh.ARRAY_TEX_UV] else PackedVector2Array()
	
	# Add vertices (transformed to world position)
	for v in mesh_verts:
		verts.append(v + world_pos)
	
	# Add indices (offset by current vertex count)
	for idx in mesh_indices:
		indices.append(idx + vertex_offset)
	
	# Add normals
	for n in mesh_normals:
		normals.append(n)
	
	# Add UVs (or default if none)
	if mesh_uvs.size() == mesh_verts.size():
		for uv in mesh_uvs:
			uvs.append(uv)
	else:
		for i in range(mesh_verts.size()):
			uvs.append(Vector2.ZERO)
	
	return vertex_offset + mesh_verts.size()


func generate_optimized_level_mesh_multi_material() -> ArrayMesh:
	"""Generate mesh with separate surfaces per tile type (better for different materials)"""
	
	var mesh = ArrayMesh.new()
	
	# Group by tile type
	var tiles_by_type = {}
	for pos in tiles:
		var tile_type = tiles[pos]
		if tile_type not in tiles_by_type:
			tiles_by_type[tile_type] = []
		tiles_by_type[tile_type].append(pos)
	
	print("Optimizing ", tiles.size(), " tiles into multi-material mesh...")
	
	# Create one surface per tile type
	for tile_type in tiles_by_type:
		var positions = tiles_by_type[tile_type]
		print("  Processing tile type ", tile_type, ": ", positions.size(), " instances")
		
		var all_verts = PackedVector3Array()
		var all_indices = PackedInt32Array()
		var all_normals = PackedVector3Array()
		var all_uvs = PackedVector2Array()
		var vertex_offset = 0
		
		# Combine all tiles of this type
		for pos in positions:
			var neighbors = get_neighbors(pos)
			var tile_mesh: ArrayMesh
			
			if tile_type in custom_meshes:
				tile_mesh = generate_custom_tile_mesh(pos, tile_type, neighbors)
			else:
				tile_mesh = generate_tile_mesh(pos, tile_type, neighbors)
			
			var world_pos = grid_to_world(pos)
			
			vertex_offset = append_mesh_to_arrays(
				tile_mesh, world_pos,
				all_verts, all_indices, all_normals, all_uvs,
				vertex_offset
			)
		
		# Add surface to mesh
		if all_verts.size() > 0:
			var surface_array = []
			surface_array.resize(Mesh.ARRAY_MAX)
			surface_array[Mesh.ARRAY_VERTEX] = all_verts
			surface_array[Mesh.ARRAY_INDEX] = all_indices
			surface_array[Mesh.ARRAY_NORMAL] = all_normals
			surface_array[Mesh.ARRAY_TEX_UV] = all_uvs
			
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface_array)
			
			# Apply original material if available
			if tile_type in custom_meshes:
				var original_material = custom_meshes[tile_type].surface_get_material(0)
				if original_material:
					mesh.surface_set_material(mesh.get_surface_count() - 1, original_material)
			else:
				# Default material for standard tiles
				var material = StandardMaterial3D.new()
				if tile_type == 0:
					material.albedo_color = Color(0.7, 0.7, 0.7)  # Floor - gray
				elif tile_type == 1:
					material.albedo_color = Color(0.8, 0.5, 0.3)  # Wall - brown
				mesh.surface_set_material(mesh.get_surface_count() - 1, material)
	
	print("✓ Multi-material optimization complete!")
	print("  Surfaces: ", mesh.get_surface_count())
	
	return mesh


func export_level_to_file(filepath: String, use_multi_material: bool = true):
	"""Export the entire level as an optimized mesh file"""
	
	print("Exporting level to: ", filepath)
	
	var optimized_mesh: ArrayMesh
	if use_multi_material:
		optimized_mesh = generate_optimized_level_mesh_multi_material()
	else:
		optimized_mesh = generate_optimized_level_mesh()
	
	var success = ResourceSaver.save(optimized_mesh, filepath)
	
	if success == OK:
		print("✓ Mesh exported successfully!")
		print("  Total tiles: ", tiles.size())
		
		# Calculate statistics
		var total_triangles = 0
		for i in range(optimized_mesh.get_surface_count()):
			var arrays = optimized_mesh.surface_get_arrays(i)
			total_triangles += arrays[Mesh.ARRAY_INDEX].size() / 3
		
		print("  Total triangles: ", total_triangles)
		print("  Surfaces: ", optimized_mesh.get_surface_count())
	else:
		push_error("Failed to save mesh: " + str(success))
	
	return optimized_mesh

# ============================================================================
# MATERIAL MANAGEMENT FUNCTIONS
# ============================================================================

# Set material for a specific surface of a custom mesh
func set_custom_material(tile_type: int, surface_index: int, material: StandardMaterial3D) -> bool:
	if tile_type not in custom_meshes:
		push_error("No custom mesh for tile type: " + str(tile_type))
		return false
	
	var mesh = custom_meshes[tile_type]
	if surface_index < 0 or surface_index >= mesh.get_surface_count():
		push_error("Surface index " + str(surface_index) + " out of range. Mesh has " + str(mesh.get_surface_count()) + " surfaces")
		return false
	
	# Update materials array
	if tile_type not in custom_materials:
		custom_materials[tile_type] = []
	
	# Ensure array is large enough
	while custom_materials[tile_type].size() < mesh.get_surface_count():
		custom_materials[tile_type].append(null)
	
	custom_materials[tile_type][surface_index] = material
	
	# Apply to the base mesh
	mesh.surface_set_material(surface_index, material)
	
	# Update all tiles using this mesh type
	for pos in tiles:
		if tiles[pos] == tile_type:
			update_tile_mesh(pos)
	
	print("✓ Material updated for tile type ", tile_type, " surface ", surface_index)
	return true


# Get the number of surfaces (material slots) for a tile type
func get_surface_count(tile_type: int) -> int:
	if tile_type in custom_meshes:
		return custom_meshes[tile_type].get_surface_count()
	return 0


# Get material for a specific surface
func get_custom_material(tile_type: int, surface_index: int) -> Material:
	if tile_type in custom_materials and surface_index < custom_materials[tile_type].size():
		return custom_materials[tile_type][surface_index]
	elif tile_type in custom_meshes:
		var mesh = custom_meshes[tile_type]
		if surface_index < mesh.get_surface_count():
			return mesh.surface_get_material(surface_index)
	return null


# Create a material with custom properties
func create_custom_material(albedo_color: Color, metallic: float = 0.0, 
						   roughness: float = 1.0, emission: Color = Color.BLACK) -> StandardMaterial3D:
	var material = StandardMaterial3D.new()
	material.albedo_color = albedo_color
	material.metallic = metallic
	material.roughness = roughness
	material.emission_enabled = emission != Color.BLACK
	material.emission = emission
	material.cull_mode = BaseMaterial3D.CULL_BACK
	return material
