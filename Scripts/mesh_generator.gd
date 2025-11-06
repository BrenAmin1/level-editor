class_name MeshGenerator extends RefCounted

# Generate mesh for custom tile types with neighbor culling and conditional boundary extension
func generate_custom_tile_mesh(pos: Vector3i, tile_type: int, neighbors: Dictionary) -> ArrayMesh:
	if tile_type not in custom_meshes:
		return ArrayMesh.new()
	
	var base_mesh = custom_meshes[tile_type]
	var final_mesh = ArrayMesh.new()
	
	# Process each surface separately
	for surface_idx in range(base_mesh.get_surface_count()):
		var arrays = base_mesh.surface_get_arrays(surface_idx)
		var vertices = arrays[Mesh.ARRAY_VERTEX]
		var normals = arrays[Mesh.ARRAY_NORMAL]
		var uvs = arrays[Mesh.ARRAY_TEX_UV]
		var indices = arrays[Mesh.ARRAY_INDEX]
		
		var s = grid_size
		var interior_margin = 0.15  # Distance from boundary to consider "interior"
		
		# Build new arrays with culled faces
		var new_verts = PackedVector3Array()
		var new_normals = PackedVector3Array()
		var new_uvs = PackedVector2Array()
		var new_indices = PackedInt32Array()
		
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
			
			# Calculate face center
			var face_center = (v0 + v1 + v2) / 3.0
			
			var should_cull = false
			
			# Check if face is in an interior zone where there's a neighbor
			# West side interior zone
			if neighbors["west"] != -1 and not should_render_vertical_face(pos, pos + Vector3i(-1, 0, 0)):
				if face_center.x < interior_margin:
					# This face is in the interior zone between this block and west neighbor
					# Cull it if it's not facing outward (away from the interior)
					if face_normal.x > -0.7:  # Not strongly facing west (outward)
						should_cull = true
			
			# East side interior zone
			if neighbors["east"] != -1 and not should_render_vertical_face(pos, pos + Vector3i(1, 0, 0)):
				if face_center.x > s - interior_margin:
					if face_normal.x < 0.7:  # Not strongly facing east (outward)
						should_cull = true
			
			# Down side interior zone
			if neighbors["down"] != -1 and not should_render_vertical_face(pos, pos + Vector3i(0, -1, 0)):
				if face_center.y < interior_margin:
					if face_normal.y > -0.7:  # Not strongly facing down (outward)
						should_cull = true
			
			# Up side interior zone
			if neighbors["up"] != -1 and not should_render_vertical_face(pos, pos + Vector3i(0, 1, 0)):
				if face_center.y > s - interior_margin:
					if face_normal.y < 0.7:  # Not strongly facing up (outward)
						should_cull = true
			
			# North side interior zone
			if neighbors["north"] != -1 and not should_render_vertical_face(pos, pos + Vector3i(0, 0, -1)):
				if face_center.z < interior_margin:
					if face_normal.z > -0.7:  # Not strongly facing north (outward)
						should_cull = true
			
			# South side interior zone
			if neighbors["south"] != -1 and not should_render_vertical_face(pos, pos + Vector3i(0, 0, 1)):
				if face_center.z > s - interior_margin:
					if face_normal.z < 0.7:  # Not strongly facing south (outward)
						should_cull = true
			
			if should_cull:
				continue
			
			# Extend vertices to boundaries only if there's a neighboring tile
			v0 = extend_vertex_to_boundary_if_neighbor(v0, neighbors, 0.35, pos)
			v1 = extend_vertex_to_boundary_if_neighbor(v1, neighbors, 0.35, pos)
			v2 = extend_vertex_to_boundary_if_neighbor(v2, neighbors, 0.35, pos)
			
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
		
		
		# Add this surface to the final mesh
		if new_verts.size() > 0:
			var surface_array = []
			surface_array.resize(Mesh.ARRAY_MAX)
			surface_array[Mesh.ARRAY_VERTEX] = new_verts
			surface_array[Mesh.ARRAY_NORMAL] = new_normals
			if new_uvs.size() > 0:
				surface_array[Mesh.ARRAY_TEX_UV] = new_uvs
			surface_array[Mesh.ARRAY_INDEX] = new_indices
			
			final_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface_array)
			
			# Apply the material from the base mesh for this surface
			var material = base_mesh.surface_get_material(surface_idx)
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
	if neighbors["up"] != -1:
		var current_offset = get_offset_for_y(pos.y)
		var neighbor_offset = get_offset_for_y(pos.y + 1)
		
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
	var has_down_neighbor = neighbors["down"] != -1
	if has_down_neighbor and v.y < grid_size * 0.5:
		var current_offset = get_offset_for_y(pos.y)
		var neighbor_offset = get_offset_for_y(pos.y - 1)
		var offset_diff = current_offset - neighbor_offset
		var extra_extension = abs(offset_diff.y)
		result.y = -extra_extension
	
	# X-axis extension - conservative for corners
	if near_x_min:
		var has_west_neighbor = neighbors["west"] != -1
		# Don't extend if we're at a corner and only have perpendicular neighbor
		if near_z_min and neighbors["north"] != -1 and not has_west_neighbor:
			pass
		elif near_z_max and neighbors["south"] != -1 and not has_west_neighbor:
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
	
	# Z-axis extension - conservative for corners
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
