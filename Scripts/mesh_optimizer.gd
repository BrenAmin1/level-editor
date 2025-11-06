class_name MeshOptimizer extends RefCounted

# References to parent TileMap3D data and components
var tiles: Dictionary  # Reference to TileMap3D.tiles
var custom_meshes: Dictionary  # Reference to TileMap3D.custom_meshes
var tile_map: TileMap3D  # Reference to parent for calling methods
var mesh_generator: MeshGenerator  # Reference to MeshGenerator component

# ============================================================================
# SETUP
# ============================================================================

func setup(tilemap: TileMap3D, tiles_ref: Dictionary, meshes_ref: Dictionary, generator: MeshGenerator):
	tile_map = tilemap
	tiles = tiles_ref
	custom_meshes = meshes_ref
	mesh_generator = generator

# ============================================================================
# MESH OPTIMIZATION FUNCTIONS
# ============================================================================

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
				var neighbors = tile_map.get_neighbors(pos)
				var tile_mesh = mesh_generator.generate_custom_tile_mesh(pos, tile_type, neighbors)
				var world_pos = tile_map.grid_to_world(pos)
				
				# Add this mesh instance to combined mesh
				vertex_offset = append_mesh_to_arrays(
					tile_mesh, world_pos,
					all_verts, all_indices, all_normals, all_uvs,
					vertex_offset
				)
		else:
			# Standard tiles - bake each with neighbor culling
			for pos in positions:
				var neighbors = tile_map.get_neighbors(pos)
				var tile_mesh = mesh_generator.generate_tile_mesh(pos, tile_type, neighbors)
				var world_pos = tile_map.grid_to_world(pos)
				
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
			var neighbors = tile_map.get_neighbors(pos)
			var tile_mesh: ArrayMesh
			
			if tile_type in custom_meshes:
				tile_mesh = mesh_generator.generate_custom_tile_mesh(pos, tile_type, neighbors)
			else:
				tile_mesh = mesh_generator.generate_tile_mesh(pos, tile_type, neighbors)
			
			var world_pos = tile_map.grid_to_world(pos)
			
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
