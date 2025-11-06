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
	var final_mesh = ArrayMesh.new()
	
	# Build arrays organized by surface type (top/sides/bottom)
	# We'll sort triangles into correct surfaces after vertex modification
	var triangles_by_surface = {}
	for surf_type in SurfaceType.values():
		triangles_by_surface[surf_type] = {
			MeshArrays.VERTICES: PackedVector3Array(),
			MeshArrays.NORMALS: PackedVector3Array(),
			MeshArrays.UVS: PackedVector2Array(),
			MeshArrays.INDICES: PackedInt32Array()
		}
	
	# If there's a block above, disable culling entirely to preserve extended geometry
	var has_block_above = neighbors[NeighborDir.UP] != -1
	
	# Check for exposed corners (where both adjacent sides have blocks, creating a corner)
	# These corners need bevels preserved, but we can still cull the two adjacent interior faces
	var exposed_corners = []  # Track which specific corners are exposed
	
	# Northwest corner: has north AND west neighbors, but the diagonal is exposed
	if neighbors[NeighborDir.NORTH] != -1 and neighbors[NeighborDir.WEST] != -1:
		var nw_pos = pos + Vector3i(-1, 0, -1)
		if nw_pos not in tiles:
			exposed_corners.append("NW")
	
	# Northeast corner: has north AND east neighbors, but the diagonal is exposed
	if neighbors[NeighborDir.NORTH] != -1 and neighbors[NeighborDir.EAST] != -1:
		var ne_pos = pos + Vector3i(1, 0, -1)
		if ne_pos not in tiles:
			exposed_corners.append("NE")
	
	# Southwest corner: has south AND west neighbors, but the diagonal is exposed
	if neighbors[NeighborDir.SOUTH] != -1 and neighbors[NeighborDir.WEST] != -1:
		var sw_pos = pos + Vector3i(-1, 0, 1)
		if sw_pos not in tiles:
			exposed_corners.append("SW")
	
	# Southeast corner: has south AND east neighbors, but the diagonal is exposed
	if neighbors[NeighborDir.SOUTH] != -1 and neighbors[NeighborDir.EAST] != -1:
		var se_pos = pos + Vector3i(1, 0, 1)
		if se_pos not in tiles:
			exposed_corners.append("SE")
	
	# Disable ALL culling only if there's a block above
	# For corner blocks, we'll do selective culling
	var disable_all_culling = has_block_above
	
	# Process each surface from the original mesh
	for surface_idx in range(base_mesh.get_surface_count()):
		var arrays = base_mesh.surface_get_arrays(surface_idx)
		var vertices = arrays[Mesh.ARRAY_VERTEX]
		var normals = arrays[Mesh.ARRAY_NORMAL]
		var uvs = arrays[Mesh.ARRAY_TEX_UV]
		var indices = arrays[Mesh.ARRAY_INDEX]
		
		var s = grid_size
		var interior_margin = 0.15  # Distance from boundary to consider "interior"
		
		# Process each triangle
		for i in range(0, indices.size(), 3):
			var i0 = indices[i]
			var i1 = indices[i + 1]
			var i2 = indices[i + 2]
			
			var v0 = vertices[i0]
			var v1 = vertices[i1]
			var v2 = vertices[i2]
			
			# Get face normal BEFORE extension
			var face_normal = (normals[i0] + normals[i1] + normals[i2]).normalized()
			
			# Calculate face center BEFORE extension for culling checks
			var face_center = (v0 + v1 + v2) / 3.0
			
			var should_cull = false
			
			# Only perform culling if all culling is not disabled
			if not disable_all_culling:
				# For corner blocks, allow culling of the two interior faces
				# but skip culling near the exposed corner edges
				
				# West side interior zone
				if neighbors[NeighborDir.WEST] != -1 and not should_render_vertical_face(pos, pos + Vector3i(-1, 0, 0)):
					if face_center.x < interior_margin:
						# Check if this face is near an exposed corner - if so, don't cull
						var is_near_corner = false
						if "NW" in exposed_corners and face_center.z < s * 0.5:
							is_near_corner = true
						if "SW" in exposed_corners and face_center.z > s * 0.5:
							is_near_corner = true
						
						if not is_near_corner and face_normal.x > -0.7:
							should_cull = true
				
				# East side interior zone
				if neighbors[NeighborDir.EAST] != -1 and not should_render_vertical_face(pos, pos + Vector3i(1, 0, 0)):
					if face_center.x > s - interior_margin:
						var is_near_corner = false
						if "NE" in exposed_corners and face_center.z < s * 0.5:
							is_near_corner = true
						if "SE" in exposed_corners and face_center.z > s * 0.5:
							is_near_corner = true
						
						if not is_near_corner and face_normal.x < 0.7:
							should_cull = true
				
				# Down side interior zone
				if neighbors[NeighborDir.DOWN] != -1 and not should_render_vertical_face(pos, pos + Vector3i(0, -1, 0)):
					if face_center.y < interior_margin:
						if face_normal.y > -0.7:
							should_cull = true
				
				# Up side interior zone
				if neighbors[NeighborDir.UP] != -1 and not should_render_vertical_face(pos, pos + Vector3i(0, 1, 0)):
					if face_center.y > s - interior_margin:
						if face_normal.y < 0.7:
							should_cull = true
				
				# North side interior zone
				if neighbors[NeighborDir.NORTH] != -1 and not should_render_vertical_face(pos, pos + Vector3i(0, 0, -1)):
					if face_center.z < interior_margin:
						var is_near_corner = false
						if "NW" in exposed_corners and face_center.x < s * 0.5:
							is_near_corner = true
						if "NE" in exposed_corners and face_center.x > s * 0.5:
							is_near_corner = true
						
						if not is_near_corner and face_normal.z > -0.7:
							should_cull = true
				
				# South side interior zone
				if neighbors[NeighborDir.SOUTH] != -1 and not should_render_vertical_face(pos, pos + Vector3i(0, 0, 1)):
					if face_center.z > s - interior_margin:
						var is_near_corner = false
						if "SW" in exposed_corners and face_center.x < s * 0.5:
							is_near_corner = true
						if "SE" in exposed_corners and face_center.x > s * 0.5:
							is_near_corner = true
						
						if not is_near_corner and face_normal.z < 0.7:
							should_cull = true
			
			if should_cull:
				continue
			
			# Extend vertices after culling decision
			v0 = extend_vertex_to_boundary_if_neighbor(v0, neighbors, 0.35, pos)
			v1 = extend_vertex_to_boundary_if_neighbor(v1, neighbors, 0.35, pos)
			v2 = extend_vertex_to_boundary_if_neighbor(v2, neighbors, 0.35, pos)
			
			# CRITICAL: Recalculate face normal after vertex modification
			# This ensures triangles are assigned to the correct surface
			var edge1 = v1 - v0
			var edge2 = v2 - v0
			var new_face_normal = edge1.cross(edge2).normalized()
			
			# Determine which surface this triangle should belong to based on its FINAL normal
			var target_surface: int
			
			# If normal is strongly pointing up, it's a top surface
			if new_face_normal.y > 0.8:
				target_surface = SurfaceType.TOP
			# If normal is strongly pointing down, it's a bottom surface
			elif new_face_normal.y < -0.8:
				target_surface = SurfaceType.BOTTOM
			# Otherwise it's a side surface
			else:
				target_surface = SurfaceType.SIDES
			
			# Add this triangle to the appropriate surface
			var target = triangles_by_surface[target_surface]
			var start_idx = target[MeshArrays.VERTICES].size()
			
			target[MeshArrays.VERTICES].append(v0)
			target[MeshArrays.VERTICES].append(v1)
			target[MeshArrays.VERTICES].append(v2)
			
			# Use the NEW normal for proper lighting after vertex modification
			target[MeshArrays.NORMALS].append(new_face_normal)
			target[MeshArrays.NORMALS].append(new_face_normal)
			target[MeshArrays.NORMALS].append(new_face_normal)
			
			# Preserve original UVs
			if uvs.size() > 0:
				target[MeshArrays.UVS].append(uvs[i0] if i0 < uvs.size() else Vector2.ZERO)
				target[MeshArrays.UVS].append(uvs[i1] if i1 < uvs.size() else Vector2.ZERO)
				target[MeshArrays.UVS].append(uvs[i2] if i2 < uvs.size() else Vector2.ZERO)
			
			target[MeshArrays.INDICES].append(start_idx)
			target[MeshArrays.INDICES].append(start_idx + 1)
			target[MeshArrays.INDICES].append(start_idx + 2)
	
	# Now build the final mesh with properly sorted surfaces
	# Process in order: Top, Sides, Bottom
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
			
			# Apply the correct material for this surface type
			# Check custom_materials first, then fall back to base mesh
			var material = null
			if tile_type in tile_map.custom_materials and surf_type < tile_map.custom_materials[tile_type].size():
				material = tile_map.custom_materials[tile_type][surf_type]
			if not material:
				material = base_mesh.surface_get_material(surf_type)
			if material:
				final_mesh.surface_set_material(final_mesh.get_surface_count() - 1, material)
	
	return final_mesh

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
