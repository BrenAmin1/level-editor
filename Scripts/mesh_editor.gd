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
			tile_map.update_tile_mesh(pos)
	
	return true
