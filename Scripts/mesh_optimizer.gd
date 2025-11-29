class_name MeshOptimizer extends RefCounted

# References to parent TileMap3D data and components
var tiles: Dictionary  # Reference to TileMap3D.tiles
var custom_meshes: Dictionary  # Reference to TileMap3D.custom_meshes
var custom_materials: Dictionary  # Reference to TileMap3D.custom_materials
var tile_map: TileMap3D  # Reference to parent for calling methods
var mesh_generator: MeshGenerator  # Reference to MeshGenerator component

# ============================================================================
# SETUP
# ============================================================================

func setup(tilemap: TileMap3D, tiles_ref: Dictionary, meshes_ref: Dictionary, generator: MeshGenerator, materials_ref: Dictionary):
	tile_map = tilemap
	tiles = tiles_ref
	custom_meshes = meshes_ref
	mesh_generator = generator
	custom_materials = materials_ref

# ============================================================================
# MESH OPTIMIZATION FUNCTIONS
# ============================================================================

func generate_optimized_level_mesh() -> ArrayMesh:
	"""Generate optimized mesh - handles both standard and custom tiles"""
	
	var all_verts = PackedVector3Array()
	var all_indices = PackedInt32Array()
	var all_normals = PackedVector3Array()
	var all_uvs = PackedVector2Array()
	var all_tangents = PackedFloat32Array()
	var all_colors = PackedColorArray()
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
				var neighbors = tile_map.get_neighbors(pos)
				var tile_mesh = mesh_generator.generate_custom_tile_mesh(pos, tile_type, neighbors)
				var world_pos = tile_map.grid_to_world(pos)
				
				# Add this mesh instance to combined mesh
				vertex_offset = append_mesh_to_arrays(
					tile_mesh, world_pos,
					all_verts, all_indices, all_normals, all_uvs,
					vertex_offset, all_tangents, all_colors
				)
		else:
			# Standard tiles - bake each with neighbor culling
			for pos in positions:
				var neighbors = tile_map.get_neighbors(pos)
				var tile_mesh = mesh_generator.generate_tile_mesh(tile_type, neighbors)
				var world_pos = tile_map.grid_to_world(pos)
				
				vertex_offset = append_mesh_to_arrays(
					tile_mesh, world_pos,
					all_verts, all_indices, all_normals, all_uvs,
					vertex_offset, all_tangents, all_colors
				)
	
	# Create final combined mesh
	var surface_array = []
	surface_array.resize(Mesh.ARRAY_MAX)
	surface_array[Mesh.ARRAY_VERTEX] = all_verts
	surface_array[Mesh.ARRAY_INDEX] = all_indices
	surface_array[Mesh.ARRAY_NORMAL] = all_normals
	surface_array[Mesh.ARRAY_TEX_UV] = all_uvs
	if all_tangents.size() > 0:
		surface_array[Mesh.ARRAY_TANGENT] = all_tangents
	if all_colors.size() > 0:
		surface_array[Mesh.ARRAY_COLOR] = all_colors
	
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
						   vertex_offset: int, 
						   tangents: PackedFloat32Array = PackedFloat32Array(),
						   colors: PackedColorArray = PackedColorArray()) -> int:
	"""Append a mesh instance to the combined arrays"""
	
	if mesh.get_surface_count() == 0:
		return vertex_offset
	
	var arrays = mesh.surface_get_arrays(0)
	var mesh_verts = arrays[Mesh.ARRAY_VERTEX]
	var mesh_indices = arrays[Mesh.ARRAY_INDEX]
	var mesh_normals = arrays[Mesh.ARRAY_NORMAL]
	var mesh_uvs = arrays[Mesh.ARRAY_TEX_UV] if arrays[Mesh.ARRAY_TEX_UV] else PackedVector2Array()
	var mesh_tangents = arrays[Mesh.ARRAY_TANGENT] if arrays[Mesh.ARRAY_TANGENT] else PackedFloat32Array()
	var mesh_colors = arrays[Mesh.ARRAY_COLOR] if arrays[Mesh.ARRAY_COLOR] else PackedColorArray()
	
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
	
	# Add tangents if present
	if mesh_tangents.size() > 0:
		for t in mesh_tangents:
			tangents.append(t)
	
	# Add colors if present
	if mesh_colors.size() == mesh_verts.size():
		for c in mesh_colors:
			colors.append(c)
	
	return vertex_offset + mesh_verts.size()


func generate_optimized_level_mesh_multi_material() -> ArrayMesh:
	"""Generate mesh with separate surfaces per tile type AND surface index (preserves all materials)"""
	
	var mesh = ArrayMesh.new()
	
	# Group by tile type
	var tiles_by_type = {}
	for pos in tiles:
		var tile_type = tiles[pos]
		if tile_type not in tiles_by_type:
			tiles_by_type[tile_type] = []
		tiles_by_type[tile_type].append(pos)
	
	print("Optimizing ", tiles.size(), " tiles into multi-material mesh...")
	
	# Create surfaces for each tile type
	for tile_type in tiles_by_type:
		var positions = tiles_by_type[tile_type]
		print("  Processing tile type ", tile_type, ": ", positions.size(), " instances")
		
		# For custom meshes with multiple surfaces, process each surface separately
		if tile_type in custom_meshes:
			var template_mesh = custom_meshes[tile_type]
			var num_surfaces = template_mesh.get_surface_count()
			print("    Custom mesh with ", num_surfaces, " surfaces")
			
			# Process each surface of the custom mesh
			for surface_idx in range(num_surfaces):
				var all_verts = PackedVector3Array()
				var all_indices = PackedInt32Array()
				var all_normals = PackedVector3Array()
				var all_uvs = PackedVector2Array()
				var all_tangents = PackedFloat32Array()
				var all_colors = PackedColorArray()
				var vertex_offset = 0
				
				# Combine all instances of this surface
				for pos in positions:
					var neighbors = tile_map.get_neighbors(pos)
					var tile_mesh = mesh_generator.generate_custom_tile_mesh(pos, tile_type, neighbors)
					var world_pos = tile_map.grid_to_world(pos)
					
					# Extract only this surface
					if surface_idx < tile_mesh.get_surface_count():
						vertex_offset = append_mesh_surface_to_arrays(
							tile_mesh, surface_idx, world_pos,
							all_verts, all_indices, all_normals, all_uvs,
							vertex_offset, all_tangents, all_colors
						)
				
				# Add this surface to the final mesh
				if all_verts.size() > 0:
					var surface_array = []
					surface_array.resize(Mesh.ARRAY_MAX)
					surface_array[Mesh.ARRAY_VERTEX] = all_verts
					surface_array[Mesh.ARRAY_INDEX] = all_indices
					surface_array[Mesh.ARRAY_NORMAL] = all_normals
					surface_array[Mesh.ARRAY_TEX_UV] = all_uvs
					if all_tangents.size() > 0:
						surface_array[Mesh.ARRAY_TANGENT] = all_tangents
					if all_colors.size() > 0:
						surface_array[Mesh.ARRAY_COLOR] = all_colors
					
					# Generate tangents if missing (critical for proper lighting!)
					if all_tangents.size() == 0:
						var temp_mesh = ArrayMesh.new()
						temp_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface_array)
						var st = SurfaceTool.new()
						st.create_from(temp_mesh, 0)
						st.generate_tangents()
						surface_array = st.commit_to_arrays()
					
					mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface_array)
					
					# Apply the correct material for this surface
					var material: Material = null
					
					# Try to get from custom_materials first
					if tile_type in custom_materials and custom_materials[tile_type].size() > surface_idx:
						material = custom_materials[tile_type][surface_idx]
						print("    Surface ", surface_idx, ": Applied custom material from custom_materials")
					# Fall back to template mesh material
					elif template_mesh.surface_get_material(surface_idx):
						material = template_mesh.surface_get_material(surface_idx)
						print("    Surface ", surface_idx, ": Applied material from template mesh")
					
					if material:
						mesh.surface_set_material(mesh.get_surface_count() - 1, material)
					else:
						print("    Surface ", surface_idx, ": WARNING - No material found!")
		else:
			# Standard tiles - single surface per tile type
			var all_verts = PackedVector3Array()
			var all_indices = PackedInt32Array()
			var all_normals = PackedVector3Array()
			var all_uvs = PackedVector2Array()
			var all_tangents = PackedFloat32Array()
			var all_colors = PackedColorArray()
			var vertex_offset = 0
			
			for pos in positions:
				var neighbors = tile_map.get_neighbors(pos)
				var tile_mesh = mesh_generator.generate_tile_mesh(tile_type, neighbors)
				var world_pos = tile_map.grid_to_world(pos)
				
				vertex_offset = append_mesh_to_arrays(
					tile_mesh, world_pos,
					all_verts, all_indices, all_normals, all_uvs,
					vertex_offset, all_tangents, all_colors
				)
			
			# Add surface to mesh
			if all_verts.size() > 0:
				var surface_array = []
				surface_array.resize(Mesh.ARRAY_MAX)
				surface_array[Mesh.ARRAY_VERTEX] = all_verts
				surface_array[Mesh.ARRAY_INDEX] = all_indices
				surface_array[Mesh.ARRAY_NORMAL] = all_normals
				surface_array[Mesh.ARRAY_TEX_UV] = all_uvs
				if all_tangents.size() > 0:
					surface_array[Mesh.ARRAY_TANGENT] = all_tangents
				if all_colors.size() > 0:
					surface_array[Mesh.ARRAY_COLOR] = all_colors
				
				mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface_array)
				
				# Default material for standard tiles
				var material = StandardMaterial3D.new()
				if tile_type == 0:
					material.albedo_color = Color(0.7, 0.7, 0.7)  # Floor - gray
				elif tile_type == 1:
					material.albedo_color = Color(0.8, 0.5, 0.3)  # Wall - brown
				mesh.surface_set_material(mesh.get_surface_count() - 1, material)
	
	print("✓ Multi-material optimization complete!")
	print("  Total surfaces: ", mesh.get_surface_count())
	for i in range(mesh.get_surface_count()):
		var mat = mesh.surface_get_material(i)
		print("    Surface ", i, ": ", "Material assigned" if mat else "NO MATERIAL")
	
	return mesh


func append_mesh_surface_to_arrays(mesh: ArrayMesh, surface_idx: int, world_pos: Vector3,
								   verts: PackedVector3Array, indices: PackedInt32Array,
								   normals: PackedVector3Array, uvs: PackedVector2Array,
								   vertex_offset: int,
								   tangents: PackedFloat32Array = PackedFloat32Array(),
								   colors: PackedColorArray = PackedColorArray()) -> int:
	"""Append a specific surface from a mesh instance to the combined arrays"""
	
	if surface_idx >= mesh.get_surface_count():
		return vertex_offset
	
	var arrays = mesh.surface_get_arrays(surface_idx)
	var mesh_verts = arrays[Mesh.ARRAY_VERTEX]
	var mesh_indices = arrays[Mesh.ARRAY_INDEX]
	var mesh_normals = arrays[Mesh.ARRAY_NORMAL]
	var mesh_uvs = arrays[Mesh.ARRAY_TEX_UV] if arrays[Mesh.ARRAY_TEX_UV] else PackedVector2Array()
	var mesh_tangents = arrays[Mesh.ARRAY_TANGENT] if arrays[Mesh.ARRAY_TANGENT] else PackedFloat32Array()
	var mesh_colors = arrays[Mesh.ARRAY_COLOR] if arrays[Mesh.ARRAY_COLOR] else PackedColorArray()
	
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
	
	# Add tangents if present
	if mesh_tangents.size() > 0:
		for t in mesh_tangents:
			tangents.append(t)
	
	# Add colors if present
	if mesh_colors.size() == mesh_verts.size():
		for c in mesh_colors:
			colors.append(c)
	
	return vertex_offset + mesh_verts.size()


func export_level_to_file(filepath: String, use_multi_material: bool = true):
	"""Export the entire level as an optimized mesh file (geometry only, no materials)"""
	
	print("Exporting level to: ", filepath)
	
	var optimized_mesh: ArrayMesh
	if use_multi_material:
		optimized_mesh = generate_optimized_level_mesh_multi_material()
	else:
		optimized_mesh = generate_optimized_level_mesh()
	
	# Remove all materials before saving to avoid import errors
	for i in range(optimized_mesh.get_surface_count()):
		optimized_mesh.surface_set_material(i, null)
	
	# Save just the geometry
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
# CHUNKED EXPORT - NEW
# ============================================================================

func export_level_chunked(save_name: String, chunk_size: Vector3i = Vector3i(32, 32, 32), 
						  use_multi_material: bool = true):
	"""Export level in spatial chunks for better memory management and streaming"""
	
	if tiles.is_empty():
		print("No tiles to export")
		return
	
	# Create export directory
	var export_base = "res://exports/"
	var export_dir = export_base + "exported_level_" + save_name + "/"
	
	# Ensure directories exist
	DirAccess.make_dir_recursive_absolute(export_base)
	DirAccess.make_dir_recursive_absolute(export_dir)
	
	print("\n=== CHUNKED EXPORT START ===")
	print("Save name: ", save_name)
	print("Export directory: ", export_dir)
	print("Chunk size: ", chunk_size)
	print("Total tiles: ", tiles.size())
	
	# Find bounding box of all tiles
	var bounds = _calculate_tile_bounds()
	print("Level bounds: ", bounds["min"], " to ", bounds["max"])
	
	# Divide into chunks
	var chunks = _divide_into_chunks(bounds, chunk_size)
	print("Total chunks: ", chunks.size())
	
	# Export each chunk
	for chunk in chunks:
		var chunk_tiles = _get_tiles_in_chunk(chunk)
		
		if chunk_tiles.is_empty():
			continue  # Skip empty chunks
		
		var chunk_name = "chunk_%d_%d_%d" % [chunk["coord"].x, chunk["coord"].y, chunk["coord"].z]
		var chunk_filepath = export_dir + chunk_name + ".tres"
		
		print("  Exporting chunk [%d, %d, %d]: %d tiles" % [
			chunk["coord"].x, chunk["coord"].y, chunk["coord"].z, chunk_tiles.size()
		])
		
		# Generate mesh for this chunk only
		var chunk_mesh = _generate_chunk_mesh(chunk_tiles, chunk["min"], use_multi_material)
		
		# Remove materials before saving
		for i in range(chunk_mesh.get_surface_count()):
			chunk_mesh.surface_set_material(i, null)
		
		# Save chunk
		var success = ResourceSaver.save(chunk_mesh, chunk_filepath)
		if success == OK:
			print("    ✓ Saved: ", chunk_filepath)
		else:
			push_error("    ✗ Failed to save chunk: " + str(success))
		
	
	# Save metadata file
	var metadata = {
		"save_name": save_name,
		"chunk_size": {"x": chunk_size.x, "y": chunk_size.y, "z": chunk_size.z},
		"bounds_min": {"x": bounds["min"].x, "y": bounds["min"].y, "z": bounds["min"].z},
		"bounds_max": {"x": bounds["max"].x, "y": bounds["max"].y, "z": bounds["max"].z},
		"total_tiles": tiles.size(),
		"total_chunks": chunks.size(),
		"export_date": Time.get_datetime_string_from_system()
	}
	
	var metadata_file = FileAccess.open(export_dir + "metadata.json", FileAccess.WRITE)
	if metadata_file:
		metadata_file.store_string(JSON.stringify(metadata, "\t"))
		metadata_file.close()
		print("✓ Metadata saved")
	
	print("=== CHUNKED EXPORT COMPLETE ===\n")


func _calculate_tile_bounds() -> Dictionary:
	"""Find the min/max coordinates of all tiles"""
	var min_pos = Vector3i(999999, 999999, 999999)
	var max_pos = Vector3i(-999999, -999999, -999999)
	
	for pos in tiles.keys():
		min_pos.x = mini(min_pos.x, pos.x)
		min_pos.y = mini(min_pos.y, pos.y)
		min_pos.z = mini(min_pos.z, pos.z)
		max_pos.x = maxi(max_pos.x, pos.x)
		max_pos.y = maxi(max_pos.y, pos.y)
		max_pos.z = maxi(max_pos.z, pos.z)
	
	return {"min": min_pos, "max": max_pos}


func _divide_into_chunks(bounds: Dictionary, chunk_size: Vector3i) -> Array:
	"""Divide the level space into chunks"""
	var chunks = []
	var min_pos = bounds["min"]
	var max_pos = bounds["max"]
	
	# Calculate chunk coordinates
	var min_chunk = Vector3i(
		floori(float(min_pos.x) / chunk_size.x),
		floori(float(min_pos.y) / chunk_size.y),
		floori(float(min_pos.z) / chunk_size.z)
	)
	
	var max_chunk = Vector3i(
		floori(float(max_pos.x) / chunk_size.x),
		floori(float(max_pos.y) / chunk_size.y),
		floori(float(max_pos.z) / chunk_size.z)
	)
	
	# Create chunk entries
	for cx in range(min_chunk.x, max_chunk.x + 1):
		for cy in range(min_chunk.y, max_chunk.y + 1):
			for cz in range(min_chunk.z, max_chunk.z + 1):
				var chunk_min = Vector3i(
					cx * chunk_size.x,
					cy * chunk_size.y,
					cz * chunk_size.z
				)
				var chunk_max = Vector3i(
					(cx + 1) * chunk_size.x - 1,
					(cy + 1) * chunk_size.y - 1,
					(cz + 1) * chunk_size.z - 1
				)
				
				chunks.append({
					"coord": Vector3i(cx, cy, cz),
					"min": chunk_min,
					"max": chunk_max
				})
	
	return chunks


func _get_tiles_in_chunk(chunk: Dictionary) -> Dictionary:
	"""Get all tiles that fall within a chunk's bounds"""
	var chunk_tiles = {}
	
	for pos in tiles.keys():
		if pos.x >= chunk["min"].x and pos.x <= chunk["max"].x and \
		   pos.y >= chunk["min"].y and pos.y <= chunk["max"].y and \
		   pos.z >= chunk["min"].z and pos.z <= chunk["max"].z:
			chunk_tiles[pos] = tiles[pos]
	
	return chunk_tiles


func _generate_chunk_mesh(chunk_tiles: Dictionary, _chunk_origin: Vector3i, 
						  use_multi_material: bool) -> ArrayMesh:
	"""Generate optimized mesh for a single chunk"""
	
	# Temporarily replace global tiles with chunk tiles
	var original_tiles = tiles
	tiles = chunk_tiles
	
	# Generate mesh using existing multi-material function
	var chunk_mesh: ArrayMesh
	if use_multi_material:
		chunk_mesh = generate_optimized_level_mesh_multi_material()
	else:
		chunk_mesh = generate_optimized_level_mesh()
	
	# Restore original tiles
	tiles = original_tiles
	
	return chunk_mesh
