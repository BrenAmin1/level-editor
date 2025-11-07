class_name MeshGenerator extends RefCounted

# Surface type enum for proper material assignment
enum SurfaceType {
	TOP = 0,      # Top face (grass)
	SIDES = 1,    # Side faces (dirt)
	BOTTOM = 2    # Bottom face (dirt)
}

# Mesh array components enum
enum MeshArrays {
	VERTICES,
	NORMALS,
	UVS,
	INDICES
}

# Neighbor direction enum
enum NeighborDir {
	NORTH,
	SOUTH,
	EAST,
	WEST,
	UP,
	DOWN
}

# References to parent TileMap3D data
var custom_meshes: Dictionary  # Reference to TileMap3D.custom_meshes
var tiles: Dictionary  # Reference to TileMap3D.tiles
var grid_size: float  # Reference to TileMap3D.grid_size
var tile_map: TileMap3D  # Reference to parent for calling methods

# ============================================================================
# SETUP
# ============================================================================

func setup(tilemap: TileMap3D, meshes_ref: Dictionary, tiles_ref: Dictionary, grid_sz: float):
	tile_map = tilemap
	custom_meshes = meshes_ref
	tiles = tiles_ref
	grid_size = grid_sz

# ============================================================================
# MESH GENERATION FUNCTIONS
# ============================================================================

# Generate mesh for custom tile types with neighbor culling and conditional boundary extension
func generate_custom_tile_mesh(pos: Vector3i, tile_type: int, neighbors: Dictionary) -> ArrayMesh:
	if tile_type not in custom_meshes:
		return ArrayMesh.new()
	
	var base_mesh = custom_meshes[tile_type]
	var slant_type = tile_map.get_tile_slant(pos)
	
	# Initialize surface data structures
	var triangles_by_surface = _initialize_surface_arrays()
	
	# Check culling conditions
	var has_block_above = neighbors[NeighborDir.UP] != -1
	var exposed_corners = _find_exposed_corners(pos, neighbors)
	var disable_all_culling = has_block_above
	
	# Process each surface from the base mesh
	for surface_idx in range(base_mesh.get_surface_count()):
		_process_mesh_surface(base_mesh, surface_idx, pos, neighbors, slant_type, 
							  triangles_by_surface, exposed_corners, disable_all_culling)
	
	# Build and return the final mesh
	return _build_final_mesh(triangles_by_surface, tile_type, base_mesh)


func _initialize_surface_arrays() -> Dictionary:
	var triangles_by_surface = {}
	for surf_type in SurfaceType.values():
		triangles_by_surface[surf_type] = {
			MeshArrays.VERTICES: PackedVector3Array(),
			MeshArrays.NORMALS: PackedVector3Array(),
			MeshArrays.UVS: PackedVector2Array(),
			MeshArrays.INDICES: PackedInt32Array()
		}
	return triangles_by_surface


func _find_exposed_corners(pos: Vector3i, neighbors: Dictionary) -> Array:
	var exposed_corners = []
	
	# Northwest corner
	if neighbors[NeighborDir.NORTH] != -1 and neighbors[NeighborDir.WEST] != -1:
		if (pos + Vector3i(-1, 0, -1)) not in tiles:
			exposed_corners.append("NW")
	
	# Northeast corner
	if neighbors[NeighborDir.NORTH] != -1 and neighbors[NeighborDir.EAST] != -1:
		if (pos + Vector3i(1, 0, -1)) not in tiles:
			exposed_corners.append("NE")
	
	# Southwest corner
	if neighbors[NeighborDir.SOUTH] != -1 and neighbors[NeighborDir.WEST] != -1:
		if (pos + Vector3i(-1, 0, 1)) not in tiles:
			exposed_corners.append("SW")
	
	# Southeast corner
	if neighbors[NeighborDir.SOUTH] != -1 and neighbors[NeighborDir.EAST] != -1:
		if (pos + Vector3i(1, 0, 1)) not in tiles:
			exposed_corners.append("SE")
	
	return exposed_corners


func _process_mesh_surface(base_mesh: ArrayMesh, surface_idx: int, pos: Vector3i, 
							neighbors: Dictionary, slant_type: int, triangles_by_surface: Dictionary,
							exposed_corners: Array, disable_all_culling: bool):
	var arrays = base_mesh.surface_get_arrays(surface_idx)
	var vertices = arrays[Mesh.ARRAY_VERTEX]
	var normals = arrays[Mesh.ARRAY_NORMAL]
	var uvs = arrays[Mesh.ARRAY_TEX_UV]
	var indices = arrays[Mesh.ARRAY_INDEX]
	
	var s = grid_size
	
	# DEBUG: Print neighbor info once per surface 0 (top surface)
	if surface_idx == 0 and slant_type != tile_map.SlantType.NONE:
		if slant_type == tile_map.SlantType.NW_SE:
			var nw_neighbor = pos + Vector3i(-1, 0, -1)
			var se_neighbor = pos + Vector3i(1, 0, 1)
			var has_nw = nw_neighbor in tiles and tile_map.get_tile_slant(nw_neighbor) == slant_type
			var has_se = se_neighbor in tiles and tile_map.get_tile_slant(se_neighbor) == slant_type
			print("  Tile ", pos, " NW_SE diagonal neighbors: NW=", has_nw, " (", nw_neighbor, ") SE=", has_se, " (", se_neighbor, ")")
		elif slant_type == tile_map.SlantType.NE_SW:
			var ne_neighbor = pos + Vector3i(1, 0, -1)
			var sw_neighbor = pos + Vector3i(-1, 0, 1)
			var has_ne = ne_neighbor in tiles and tile_map.get_tile_slant(ne_neighbor) == slant_type
			var has_sw = sw_neighbor in tiles and tile_map.get_tile_slant(sw_neighbor) == slant_type
			print("  Tile ", pos, " NE_SW diagonal neighbors: NE=", has_ne, " (", ne_neighbor, ") SW=", has_sw, " (", sw_neighbor, ")")
	
	# Process each triangle
	for i in range(0, indices.size(), 3):
		var i0 = indices[i]
		var i1 = indices[i + 1]
		var i2 = indices[i + 2]
		
		var v0 = vertices[i0]
		var v1 = vertices[i1]
		var v2 = vertices[i2]
		
		# Apply slant rotation if needed
		if slant_type != tile_map.SlantType.NONE:
			v0 = _apply_slant_rotation(v0, slant_type, s)
			v1 = _apply_slant_rotation(v1, slant_type, s)
			v2 = _apply_slant_rotation(v2, slant_type, s)
			
			# Extend corners to connect with neighbors
			v0 = _extend_slant_vertices(v0, pos, slant_type,s)
			v1 = _extend_slant_vertices(v1, pos, slant_type,s)
			v2 = _extend_slant_vertices(v2, pos, slant_type,s)
		
		var face_normal = (normals[i0] + normals[i1] + normals[i2]).normalized()
		var face_center = (v0 + v1 + v2) / 3.0
		
		# Still check neighbor culling (unless slant is enabled - then disable all culling for now)
		if slant_type == tile_map.SlantType.NONE:
			if _should_cull_for_neighbors(pos, neighbors, face_center, face_normal, exposed_corners, 
										  disable_all_culling, s):
				continue
			
			# Extend vertices to boundaries (only if no slant)
			v0 = extend_vertex_to_boundary_if_neighbor(v0, neighbors, 0.35, pos)
			v1 = extend_vertex_to_boundary_if_neighbor(v1, neighbors, 0.35, pos)
			v2 = extend_vertex_to_boundary_if_neighbor(v2, neighbors, 0.35, pos)
		
		# Add triangle to appropriate surface
		_add_triangle_to_surface(triangles_by_surface, v0, v1, v2, uvs, i0, i1, i2, normals)



func _extend_slant_vertices(v: Vector3, pos: Vector3i, slant_type: int, grid_s: float) -> Vector3:
	var result = v
	
	# Check diagonal neighbors for matching slants
	var nw_pos = pos + Vector3i(-1, 0, -1)
	var ne_pos = pos + Vector3i(1, 0, -1)
	var sw_pos = pos + Vector3i(-1, 0, 1)
	var se_pos = pos + Vector3i(1, 0, 1)
	
	var has_nw_slant = (nw_pos in tiles and tile_map.get_tile_slant(nw_pos) == slant_type)
	var has_ne_slant = (ne_pos in tiles and tile_map.get_tile_slant(ne_pos) == slant_type)
	var has_sw_slant = (sw_pos in tiles and tile_map.get_tile_slant(sw_pos) == slant_type)
	var has_se_slant = (se_pos in tiles and tile_map.get_tile_slant(se_pos) == slant_type)
	
	var extension_distance = grid_s * 0.35  # How far to extend beyond boundary
	
	match slant_type:
		tile_map.SlantType.NW_SE:
			# The diagonal line runs from NW (0,0) to SE (grid_s, grid_s)
			# We need to extend vertices that are near this diagonal line
			
			if has_nw_slant:
				# For NW connection: vertices where x ≈ z and both are small
				# Distance to NW-SE diagonal line through origin
				var dist_to_diagonal = abs(v.x - v.z) / sqrt(2.0)
				var dist_along_diagonal = (v.x + v.z) / sqrt(2.0)
				
				# If vertex is near the diagonal line AND close to the NW edge
				if dist_to_diagonal < grid_s * 0.3 and dist_along_diagonal < grid_s * 0.6:
					# Extend along the diagonal towards NW
					result.x = v.x - extension_distance
					result.z = v.z - extension_distance
			
			if has_se_slant:
				# For SE connection: vertices where x ≈ z and both are large
				var dist_to_diagonal = abs(v.x - v.z) / sqrt(2.0)
				var dist_along_diagonal = (v.x + v.z) / sqrt(2.0)
				
				# If vertex is near the diagonal line AND close to the SE edge
				if dist_to_diagonal < grid_s * 0.3 and dist_along_diagonal > grid_s * 0.8:
					result.x = v.x + extension_distance
					result.z = v.z + extension_distance
		
		tile_map.SlantType.NE_SW:
			# The diagonal line runs from NE (grid_s, 0) to SW (0, grid_s)
			
			if has_ne_slant:
				# For NE connection: vertices where (grid_s - x) ≈ z
				# Distance to NE-SW diagonal line
				var dist_to_diagonal = abs((grid_s - v.x) - v.z) / sqrt(2.0)
				var dist_along_diagonal = ((grid_s - v.x) + v.z) / sqrt(2.0)
				
				# If near the diagonal and close to NE edge
				if dist_to_diagonal < grid_s * 0.3 and dist_along_diagonal < grid_s * 0.6:
					result.x = v.x + extension_distance
					result.z = v.z - extension_distance
			
			if has_sw_slant:
				# For SW connection: vertices where x ≈ (grid_s - z)
				var dist_to_diagonal = abs((grid_s - v.x) - v.z) / sqrt(2.0)
				var dist_along_diagonal = ((grid_s - v.x) + v.z) / sqrt(2.0)
				
				# If near the diagonal and close to SW edge
				if dist_to_diagonal < grid_s * 0.3 and dist_along_diagonal > grid_s * 0.8:
					result.x = v.x - extension_distance
					result.z = v.z + extension_distance
	
	return result


func _apply_slant_rotation(v: Vector3, slant_type: int, grid_s: float) -> Vector3:
	# Rotate the mesh 45 degrees around the Y axis to align bevels with diagonal
	var center = Vector3(grid_s * 0.5, 0, grid_s * 0.5)
	var relative = v - center
	
	match slant_type:
		tile_map.SlantType.NW_SE:
			# Rotate -45 degrees (align with NW-SE diagonal)
			var angle = -PI / 4.0
			var cos_a = cos(angle)
			var sin_a = sin(angle)
			var rotated = Vector3(
				relative.x * cos_a - relative.z * sin_a,
				relative.y,
				relative.x * sin_a + relative.z * cos_a
			)
			return rotated + center
			
		tile_map.SlantType.NE_SW:
			# Rotate 45 degrees (align with NE-SW diagonal)
			var angle = PI / 4.0
			var cos_a = cos(angle)
			var sin_a = sin(angle)
			var rotated = Vector3(
				relative.x * cos_a - relative.z * sin_a,
				relative.y,
				relative.x * sin_a + relative.z * cos_a
			)
			return rotated + center
	
	return v


# Add triangle to appropriate surface
func _add_triangle_to_surface(triangles_by_surface: Dictionary, v0: Vector3, v1: Vector3, v2: Vector3,
							   uvs: PackedVector2Array, i0: int, i1: int, i2: int,
							   original_normals: PackedVector3Array):
	# Calculate face normal for surface classification
	var edge1 = v1 - v0
	var edge2 = v2 - v0
	var face_normal = edge1.cross(edge2).normalized()
	
	# Determine surface type based on face normal
	var target_surface: int
	if face_normal.y > 0.8:
		target_surface = SurfaceType.TOP
	elif face_normal.y < -0.8:
		target_surface = SurfaceType.BOTTOM
	else:
		target_surface = SurfaceType.SIDES
	
	# Add to appropriate surface
	var target = triangles_by_surface[target_surface]
	var start_idx = target[MeshArrays.VERTICES].size()
	
	target[MeshArrays.VERTICES].append(v0)
	target[MeshArrays.VERTICES].append(v1)
	target[MeshArrays.VERTICES].append(v2)
	
	# Use original vertex normals for proper lighting (not face normal!)
	target[MeshArrays.NORMALS].append(original_normals[i0])
	target[MeshArrays.NORMALS].append(original_normals[i1])
	target[MeshArrays.NORMALS].append(original_normals[i2])
	
	if uvs.size() > 0:
		target[MeshArrays.UVS].append(uvs[i0] if i0 < uvs.size() else Vector2.ZERO)
		target[MeshArrays.UVS].append(uvs[i1] if i1 < uvs.size() else Vector2.ZERO)
		target[MeshArrays.UVS].append(uvs[i2] if i2 < uvs.size() else Vector2.ZERO)
	
	target[MeshArrays.INDICES].append(start_idx)
	target[MeshArrays.INDICES].append(start_idx + 1)
	target[MeshArrays.INDICES].append(start_idx + 2)

func _should_cull_for_neighbors(pos: Vector3i, neighbors: Dictionary, face_center: Vector3, 
								face_normal: Vector3, exposed_corners: Array, 
								disable_all_culling: bool, s: float) -> bool:
	if disable_all_culling:
		return false
	
	var interior_margin = 0.15
	
	# West side culling
	if neighbors[NeighborDir.WEST] != -1 and not should_render_vertical_face(pos, pos + Vector3i(-1, 0, 0)):
		if face_center.x < interior_margin:
			var is_near_corner = ("NW" in exposed_corners and face_center.z < s * 0.5) or \
								 ("SW" in exposed_corners and face_center.z > s * 0.5)
			if not is_near_corner and face_normal.x < -0.7:  # Face pointing west
				return true
	
	# East side culling
	if neighbors[NeighborDir.EAST] != -1 and not should_render_vertical_face(pos, pos + Vector3i(1, 0, 0)):
		if face_center.x > s - interior_margin:
			var is_near_corner = ("NE" in exposed_corners and face_center.z < s * 0.5) or \
								 ("SE" in exposed_corners and face_center.z > s * 0.5)
			if not is_near_corner and face_normal.x > 0.7:  # Face pointing east
				return true
	
	# Down side culling - FIXED: Cull faces pointing downward (negative Y normal)
	if neighbors[NeighborDir.DOWN] != -1 and not should_render_vertical_face(pos, pos + Vector3i(0, -1, 0)):
		if face_center.y < interior_margin and face_normal.y < -0.7:  # Face pointing down
			return true
	
	# Up side culling
	if neighbors[NeighborDir.UP] != -1 and not should_render_vertical_face(pos, pos + Vector3i(0, 1, 0)):
		if face_center.y > s - interior_margin and face_normal.y > 0.7:  # Face pointing up
			return true
	
	# North side culling
	if neighbors[NeighborDir.NORTH] != -1 and not should_render_vertical_face(pos, pos + Vector3i(0, 0, -1)):
		if face_center.z < interior_margin:
			var is_near_corner = ("NW" in exposed_corners and face_center.x < s * 0.5) or \
								 ("NE" in exposed_corners and face_center.x > s * 0.5)
			if not is_near_corner and face_normal.z < -0.7:  # Face pointing north
				return true
	
	# South side culling
	if neighbors[NeighborDir.SOUTH] != -1 and not should_render_vertical_face(pos, pos + Vector3i(0, 0, 1)):
		if face_center.z > s - interior_margin:
			var is_near_corner = ("SW" in exposed_corners and face_center.x < s * 0.5) or \
								 ("SE" in exposed_corners and face_center.x > s * 0.5)
			if not is_near_corner and face_normal.z > 0.7:  # Face pointing south
				return true
	
	return false


func _build_final_mesh(triangles_by_surface: Dictionary, tile_type: int, base_mesh: ArrayMesh) -> ArrayMesh:
	var final_mesh = ArrayMesh.new()
	
	for surf_type in [SurfaceType.TOP, SurfaceType.SIDES, SurfaceType.BOTTOM]:
		var surf_data = triangles_by_surface[surf_type]
		
		if surf_data[MeshArrays.VERTICES].size() > 0:
			var surface_array = []
			surface_array.resize(Mesh.ARRAY_MAX)
			surface_array[Mesh.ARRAY_VERTEX] = surf_data[MeshArrays.VERTICES]
			surface_array[Mesh.ARRAY_NORMAL] = surf_data[MeshArrays.NORMALS]
			if surf_data[MeshArrays.UVS].size() > 0:
				surface_array[Mesh.ARRAY_TEX_UV] = surf_data[MeshArrays.UVS]
			surface_array[Mesh.ARRAY_INDEX] = surf_data[MeshArrays.INDICES]
			
			final_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface_array)
			
			# Apply materials
			var material = null
			if tile_type in tile_map.custom_materials and surf_type < tile_map.custom_materials[tile_type].size():
				material = tile_map.custom_materials[tile_type][surf_type]
			if not material:
				material = base_mesh.surface_get_material(surf_type)
			if material:
				final_mesh.surface_set_material(final_mesh.get_surface_count() - 1, material)
	
	return final_mesh


func _should_cull_triangle_for_slant(v0: Vector3, v1: Vector3, v2: Vector3, slant_type: int, grid_s: float) -> bool:
	match slant_type:
		tile_map.SlantType.NW_SE:
			var v0_cull = (v0.x + v0.z) > grid_s
			var v1_cull = (v1.x + v1.z) > grid_s
			var v2_cull = (v2.x + v2.z) > grid_s
			return v0_cull and v1_cull and v2_cull
			
		tile_map.SlantType.NE_SW:
			var v0_cull = v0.x > (grid_s - v0.z)
			var v1_cull = v1.x > (grid_s - v1.z)
			var v2_cull = v2.x > (grid_s - v2.z)
			return v0_cull and v1_cull and v2_cull
	
	return false


# Helper function to extend a vertex to boundary only if there's a neighbor in that direction
# For corner vertices, only extend on axes where neighbors exist
func extend_vertex_to_boundary_if_neighbor(v: Vector3, neighbors: Dictionary, threshold: float, pos: Vector3i) -> Vector3:
	var result = v
	
	# Determine which boundaries this vertex is near
	var near_x_min = v.x < threshold
	var near_x_max = v.x > grid_size - threshold
	var near_y_max = v.y > grid_size - threshold
	var near_z_min = v.z < threshold
	var near_z_max = v.z > grid_size - threshold
	
	# Special case: if there's a block above, remove ALL bevels
	if neighbors[NeighborDir.UP] != -1:
		var current_offset = tile_map.get_offset_for_y(pos.y)
		var neighbor_offset = tile_map.get_offset_for_y(pos.y + 1)
		
		if current_offset.is_equal_approx(neighbor_offset):
			if v.x < grid_size * 0.5:
				result.x = 0
			else:
				result.x = grid_size
			
			if v.y < grid_size * 0.5:
				result.y = 0
			else:
				result.y = grid_size
			
			if v.z < grid_size * 0.5:
				result.z = 0
			else:
				result.z = grid_size
			
			return result
	
	# If there's a tile below, extend bottom vertices
	var has_down_neighbor = neighbors[NeighborDir.DOWN] != -1
	if has_down_neighbor and v.y < grid_size * 0.5:
		var current_offset = tile_map.get_offset_for_y(pos.y)
		var neighbor_offset = tile_map.get_offset_for_y(pos.y - 1)
		var offset_diff = current_offset - neighbor_offset
		var extra_extension = abs(offset_diff.y)
		result.y = -extra_extension
	
	# X-axis extension - conservative for corners
	if near_x_min:
		var has_west_neighbor = neighbors[NeighborDir.WEST] != -1
		# Don't extend if we're at a corner and only have perpendicular neighbor
		if near_z_min and neighbors[NeighborDir.NORTH] != -1 and not has_west_neighbor:
			pass
		elif near_z_max and neighbors[NeighborDir.SOUTH] != -1 and not has_west_neighbor:
			pass
		elif has_west_neighbor:
			result.x = 0
			
	elif near_x_max:
		var has_east_neighbor = neighbors[NeighborDir.EAST] != -1
		if near_z_min and neighbors[NeighborDir.NORTH] != -1 and not has_east_neighbor:
			pass
		elif near_z_max and neighbors[NeighborDir.SOUTH] != -1 and not has_east_neighbor:
			pass
		elif has_east_neighbor:
			result.x = grid_size
	
	# Top face handling
	if near_y_max:
		var has_up_neighbor = neighbors[NeighborDir.UP] != -1
		if near_x_min and neighbors[NeighborDir.WEST] != -1 and not has_up_neighbor:
			pass
		elif near_x_max and neighbors[NeighborDir.EAST] != -1 and not has_up_neighbor:
			pass
		elif near_z_min and neighbors[NeighborDir.NORTH] != -1 and not has_up_neighbor:
			pass
		elif near_z_max and neighbors[NeighborDir.SOUTH] != -1 and not has_up_neighbor:
			pass
		elif has_up_neighbor:
			result.y = grid_size
	
	# Z-axis extension - conservative for corners
	if near_z_min:
		var has_north_neighbor = neighbors[NeighborDir.NORTH] != -1
		if near_x_min and neighbors[NeighborDir.WEST] != -1 and not has_north_neighbor:
			pass
		elif near_x_max and neighbors[NeighborDir.EAST] != -1 and not has_north_neighbor:
			pass
		elif has_north_neighbor:
			result.z = 0
			
	elif near_z_max:
		var has_south_neighbor = neighbors[NeighborDir.SOUTH] != -1
		if near_x_min and neighbors[NeighborDir.WEST] != -1 and not has_south_neighbor:
			pass
		elif near_x_max and neighbors[NeighborDir.EAST] != -1 and not has_south_neighbor:
			pass
		elif has_south_neighbor:
			result.z = grid_size
	
	return result




func should_render_vertical_face(current_pos: Vector3i, neighbor_pos: Vector3i) -> bool:
	if neighbor_pos not in tiles:
		return true
	
	var current_offset = tile_map.get_offset_for_y(current_pos.y)
	var neighbor_offset = tile_map.get_offset_for_y(neighbor_pos.y)
	
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
	
	if neighbors[NeighborDir.NORTH] == -1:
		add_quad(verts, indices, normals, uvs,
			Vector3(0, 0, 0), Vector3(s, 0, 0),
			Vector3(s, s, 0), Vector3(0, s, 0),
			Vector3(0, 0, -1))
	
	if neighbors[NeighborDir.SOUTH] == -1:
		add_quad(verts, indices, normals, uvs,
			Vector3(s, 0, s), Vector3(0, 0, s),
			Vector3(0, s, s), Vector3(s, s, s),
			Vector3(0, 0, 1))
	
	if neighbors[NeighborDir.EAST] == -1:
		add_quad(verts, indices, normals, uvs,
			Vector3(s, 0, 0), Vector3(s, 0, s),
			Vector3(s, s, s), Vector3(s, s, 0),
			Vector3(1, 0, 0))
	
	if neighbors[NeighborDir.WEST] == -1:
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
