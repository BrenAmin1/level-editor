class_name MeshEditor extends RefCounted

# References to parent TileMap3D data
var custom_meshes: Dictionary  # Reference to TileMap3D.custom_meshes
var tiles: Dictionary  # Reference to TileMap3D.tiles
var tile_map: TileMap3D  # Reference to parent for calling update_tile_mesh

# ============================================================================
# SETUP
# ============================================================================

func setup(tilemap: TileMap3D, meshes_ref: Dictionary, tiles_ref: Dictionary):
	tile_map = tilemap
	custom_meshes = meshes_ref
	tiles = tiles_ref

# ============================================================================
# MESH EDITING FUNCTIONS
# ============================================================================

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
			tile_map.update_tile_mesh(pos)
	
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


# Recalculate normals for a mesh using an angle threshold to preserve hard edges.
# Faces whose normals differ by more than SMOOTH_ANGLE_DEG get split into
# separate vertices so hard corners stay sharp instead of producing blurry
# smooth-shading artifacts.
func recalculate_normals(tile_type: int, smooth_angle_deg: float = 30.0) -> bool:
	if tile_type not in custom_meshes:
		return false

	var mesh = custom_meshes[tile_type]
	var new_mesh = ArrayMesh.new()
	var cos_threshold: float = cos(deg_to_rad(smooth_angle_deg))

	for surface_idx in range(mesh.get_surface_count()):
		var arrays  = mesh.surface_get_arrays(surface_idx)
		var src_verts:   PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var src_uvs:     PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
		var src_indices: PackedInt32Array   = arrays[Mesh.ARRAY_INDEX]

		var tri_count: int = floori(src_indices.size() / 3.0)

		# --- Step 1: compute one flat normal per triangle ---
		var face_normals: Array[Vector3] = []
		face_normals.resize(tri_count)
		for t in range(tri_count):
			var i0 = src_indices[t * 3]
			var i1 = src_indices[t * 3 + 1]
			var i2 = src_indices[t * 3 + 2]
			var e1 = src_verts[i1] - src_verts[i0]
			var e2 = src_verts[i2] - src_verts[i0]
			face_normals[t] = e1.cross(e2).normalized()

		# --- Step 2: build a position -> [triangle indices] map ---
		# Key: snapped Vector3 string; Value: Array of triangle indices
		var pos_to_tris: Dictionary = {}
		for t in range(tri_count):
			for c in range(3):
				var vi = src_indices[t * 3 + c]
				var key = _snap_key(src_verts[vi])
				if not pos_to_tris.has(key):
					pos_to_tris[key] = []
				pos_to_tris[key].append(t)

		# --- Step 3: for every (vertex, triangle) pair compute a smooth normal ---
		# Only average face normals whose angle to the face normal is <= threshold.
		# Result stored per (original_vertex_index, triangle_index).
		var smooth_normals: Dictionary = {}  # key: "%d_%d" % [vi, ti]
		for t in range(tri_count):
			for c in range(3):
				var vi = src_indices[t * 3 + c]
				var key = _snap_key(src_verts[vi])
				var fn: Vector3 = face_normals[t]
				var accum: Vector3 = Vector3.ZERO
				for nb_t in pos_to_tris[key]:
					if fn.dot(face_normals[nb_t]) >= cos_threshold:
						accum += face_normals[nb_t]
				smooth_normals["%d_%d" % [vi, t]] = accum.normalized()

		# --- Step 4: unindex — every triangle corner becomes its own vertex ---
		var out_verts:   PackedVector3Array = PackedVector3Array()
		var out_normals: PackedVector3Array = PackedVector3Array()
		var out_uvs:     PackedVector2Array = PackedVector2Array()
		var out_indices: PackedInt32Array   = PackedInt32Array()

		for t in range(tri_count):
			var base: int = out_verts.size()
			for c in range(3):
				var vi = src_indices[t * 3 + c]
				out_verts.append(src_verts[vi])
				out_normals.append(smooth_normals["%d_%d" % [vi, t]])
				out_uvs.append(src_uvs[vi] if src_uvs and vi < src_uvs.size() else Vector2.ZERO)
				out_indices.append(base + c)

		var surface_array = []
		surface_array.resize(Mesh.ARRAY_MAX)
		surface_array[Mesh.ARRAY_VERTEX]  = out_verts
		surface_array[Mesh.ARRAY_NORMAL]  = out_normals
		surface_array[Mesh.ARRAY_TEX_UV]  = out_uvs
		surface_array[Mesh.ARRAY_INDEX]   = out_indices

		new_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface_array)
		new_mesh.surface_set_material(surface_idx, mesh.surface_get_material(surface_idx))

	custom_meshes[tile_type] = new_mesh

	# Update all tiles using this mesh
	for pos in tiles:
		if tiles[pos] == tile_type:
			tile_map.update_tile_mesh(pos)

	return true


# Snap a Vector3 to a fixed grid for position-equality comparisons.
func _snap_key(v: Vector3) -> String:
	const PRECISION := 10000.0
	return "%d_%d_%d" % [roundi(v.x * PRECISION), roundi(v.y * PRECISION), roundi(v.z * PRECISION)]
