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
	"""Export the entire level as an optimized mesh file"""
	
	print("Exporting level to: ", filepath)
	
	var optimized_mesh: ArrayMesh
	if use_multi_material:
		optimized_mesh = generate_optimized_level_mesh_multi_material()
	else:
		optimized_mesh = generate_optimized_level_mesh()
	
	# CRITICAL: Duplicate materials so they're embedded in the resource
	# Without this, material references are lost on save
	for i in range(optimized_mesh.get_surface_count()):
		var mat = optimized_mesh.surface_get_material(i)
		if mat:
			# Duplicate the material so it becomes part of this resource
			var duplicated_mat = mat.duplicate()
			optimized_mesh.surface_set_material(i, duplicated_mat)
			print("  Surface ", i, ": Embedded material (", duplicated_mat.get_class(), ")")
	
	# Save with FLAG_BUNDLE_RESOURCES to ensure materials are saved with the mesh
	var success = ResourceSaver.save(optimized_mesh, filepath, ResourceSaver.FLAG_BUNDLE_RESOURCES)
	
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
