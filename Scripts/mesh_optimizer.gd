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

var progress_callback: Callable  # Optional: called with (done: int, total: int) from worker thread

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

	var _prog_total = tiles.size()
	var _prog_done = 0

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
				var tile_mesh: ArrayMesh
				# Stairs must go through generate_custom_tile_mesh so per-tile rotation is applied
				if tile_type == MeshGenerator.TILE_TYPE_STAIRS:
					var rotation = tile_map.tile_rotations.get(pos, 0.0)
					tile_mesh = mesh_generator.generate_custom_tile_mesh(pos, tile_type, neighbors, rotation)
				else:
					tile_mesh = mesh_generator.generate_tile_mesh(tile_type, neighbors)
				var world_pos = tile_map.grid_to_world(pos)
				
				vertex_offset = append_mesh_to_arrays(
					tile_mesh, world_pos,
					all_verts, all_indices, all_normals, all_uvs,
					vertex_offset, all_tangents, all_colors
				)
				_prog_done += 1
				if progress_callback.is_valid():
					progress_callback.call_deferred(_prog_done, _prog_total)
	
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
	"""
	Generate mesh with one surface per (tile_type, surface_index, palette_material_index)
	combination so every per-tile painted material is preserved in the export.
	"""
	var mesh = ArrayMesh.new()

	# ------------------------------------------------------------------
	# 1. Build a lookup: pos -> palette_material_index (-1 if none)
	# ------------------------------------------------------------------
	var tile_palette_index: Dictionary = {}  # Vector3i -> int
	if tile_map and tile_map.tile_materials:
		for pos in tile_map.tile_materials:
			tile_palette_index[pos] = int(tile_map.tile_materials[pos])

	# ------------------------------------------------------------------
	# 2. Group positions by (tile_type, palette_material_index)
	#    Key: String "tile_type:mat_idx"  (mat_idx = -1 for unpainted)
	# ------------------------------------------------------------------
	var groups: Dictionary = {}  # String -> { tile_type, mat_idx, positions[] }
	for pos in tiles:
		var tile_type = tiles[pos]
		var mat_idx = tile_palette_index.get(pos, -1)
		var key = str(tile_type) + ":" + str(mat_idx)
		if key not in groups:
			groups[key] = { "tile_type": tile_type, "mat_idx": mat_idx, "positions": [] }
		groups[key]["positions"].append(pos)

	print("Optimizing ", tiles.size(), " tiles into multi-material mesh...")
	print("  Unique (tile_type × palette_material) groups: ", groups.size())

	var _prog_total = tiles.size()
	var _prog_done = 0

	# ------------------------------------------------------------------
	# 3. For each group, build one surface per mesh surface index
	# ------------------------------------------------------------------
	for key in groups:
		var group = groups[key]
		var tile_type: int = group["tile_type"]
		var mat_idx: int = group["mat_idx"]
		var positions: Array = group["positions"]

		# Resolve the Material object for this group — kept for reference by surface loops below.
		# Note: per-surface resolution is now done inside each surface loop via
		# get_material_for_surface(mat_idx, surface_idx) so top/side/bottom get correct textures.
		var _palette_material_unused: Material = null  # Unused; retained for clarity only.

		if tile_type in custom_meshes:
			var template_mesh = custom_meshes[tile_type]
			var num_surfaces = template_mesh.get_surface_count()

			# Cache generated meshes keyed by position so each tile is only built once,
			# not once per surface (which would be num_surfaces times the work).
			var mesh_cache: Dictionary = {}  # Vector3i -> ArrayMesh
			for pos in positions:
				var neighbors = tile_map.get_neighbors(pos)
				var rotation = tile_map.tile_rotations.get(pos, 0.0)
				mesh_cache[pos] = mesh_generator.generate_custom_tile_mesh(pos, tile_type, neighbors, rotation)
				_prog_done += 1
				if progress_callback.is_valid():
					progress_callback.call_deferred(_prog_done, _prog_total)

			for surface_idx in range(num_surfaces):
				var all_verts = PackedVector3Array()
				var all_indices = PackedInt32Array()
				var all_normals = PackedVector3Array()
				var all_uvs = PackedVector2Array()
				var all_tangents = PackedFloat32Array()
				var all_colors = PackedColorArray()
				var vertex_offset = 0

				for pos in positions:
					var tile_mesh: ArrayMesh = mesh_cache[pos]
					var world_pos = tile_map.grid_to_world(pos)
					if surface_idx < tile_mesh.get_surface_count():
						vertex_offset = append_mesh_surface_to_arrays(
							tile_mesh, surface_idx, world_pos,
							all_verts, all_indices, all_normals, all_uvs,
							vertex_offset, all_tangents, all_colors
						)

				if all_verts.size() == 0:
					continue

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

				if all_tangents.size() == 0:
					var temp_mesh = ArrayMesh.new()
					temp_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface_array)
					var st = SurfaceTool.new()
					st.create_from(temp_mesh, 0)
					st.generate_tangents()
					surface_array = st.commit_to_arrays()

				mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface_array)

				# Priority: per-surface palette material > custom_materials > template mesh material
				# Use get_material_for_surface if available so top/side/bottom get distinct textures.
				var material: Material = null
				if mat_idx >= 0 and tile_map and tile_map.material_palette_ref:
					var palette = tile_map.material_palette_ref
					if palette.has_method("get_material_for_surface"):
						material = palette.get_material_for_surface(mat_idx, surface_idx)
					elif palette.has_method("get_material_at_index"):
						material = palette.get_material_at_index(mat_idx)
				if material == null and tile_type in custom_materials and custom_materials[tile_type].size() > surface_idx:
					material = custom_materials[tile_type][surface_idx]
				if material == null and template_mesh.surface_get_material(surface_idx):
					material = template_mesh.surface_get_material(surface_idx)

				if material:
					mesh.surface_set_material(mesh.get_surface_count() - 1, material)
		else:
			# Standard (procedural) tile type — one surface per mesh surface index.
			# Stairs are procedural but need per-tile rotation, so we determine the
			# number of surfaces from a sample mesh and iterate like custom tiles do.
			var is_stairs = (tile_type == MeshGenerator.TILE_TYPE_STAIRS)

			# Cache generated meshes keyed by position so each tile is only built once,
			# not once per surface (which would be num_surfaces times the work).
			var mesh_cache: Dictionary = {}  # Vector3i -> ArrayMesh
			for pos in positions:
				var neighbors = tile_map.get_neighbors(pos)
				if is_stairs:
					var rotation = tile_map.tile_rotations.get(pos, 0.0)
					mesh_cache[pos] = mesh_generator.generate_custom_tile_mesh(pos, tile_type, neighbors, rotation)
				else:
					mesh_cache[pos] = mesh_generator.generate_tile_mesh(tile_type, neighbors)
				_prog_done += 1
				if progress_callback.is_valid():
					progress_callback.call_deferred(_prog_done, _prog_total)

			# Determine surface count from the first cached mesh.
			var num_surfaces = max(1, mesh_cache[positions[0]].get_surface_count())

			for surface_idx in range(num_surfaces):
				var all_verts = PackedVector3Array()
				var all_indices = PackedInt32Array()
				var all_normals = PackedVector3Array()
				var all_uvs = PackedVector2Array()
				var all_tangents = PackedFloat32Array()
				var all_colors = PackedColorArray()
				var vertex_offset = 0

				for pos in positions:
					var tile_mesh: ArrayMesh = mesh_cache[pos]
					var world_pos = tile_map.grid_to_world(pos)
					if surface_idx < tile_mesh.get_surface_count():
						vertex_offset = append_mesh_surface_to_arrays(
							tile_mesh, surface_idx, world_pos,
							all_verts, all_indices, all_normals, all_uvs,
							vertex_offset, all_tangents, all_colors
						)

				if all_verts.size() == 0:
					continue

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

				# Resolve material per-surface so that, e.g., a "Grass" palette entry
				# correctly applies Grass.png to the top (surface 0) and dirt.png to the
				# sides (surface 1) rather than stamping Grass.png on every surface.
				var surface_material: Material = null
				if mat_idx >= 0 and tile_map and tile_map.material_palette_ref:
					var palette = tile_map.material_palette_ref
					if palette.has_method("get_material_for_surface"):
						surface_material = palette.get_material_for_surface(mat_idx, surface_idx)
					elif palette.has_method("get_material_at_index"):
						# Fallback: palette doesn't support per-surface lookup yet
						surface_material = palette.get_material_at_index(mat_idx)
				if surface_material == null:
					var fallback = StandardMaterial3D.new()
					fallback.albedo_color = Color(0.7, 0.7, 0.7)
					surface_material = fallback
				mesh.surface_set_material(mesh.get_surface_count() - 1, surface_material)

	print("✓ Multi-material optimization complete!")
	print("  Total surfaces: ", mesh.get_surface_count())
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


func build_export_mesh(use_multi_material: bool = true) -> ArrayMesh:
	"""
	Thread-safe mesh build step — only touches tile data and returns an ArrayMesh.
	No file I/O, no scene nodes, no Godot rendering API calls.
	Call this from a worker thread; do ResourceSaver / GLTFDocument on the main thread.
	Materials are baked in directly by generate_optimized_level_mesh_multi_material.
	"""
	if use_multi_material:
		return generate_optimized_level_mesh_multi_material()
	else:
		return generate_optimized_level_mesh()


func export_level_to_file(filepath: String, use_multi_material: bool = true):
	"""Export the entire level as an optimized mesh .tres file, preserving materials"""
	
	print("Exporting level to: ", filepath)
	
	var optimized_mesh: ArrayMesh
	if use_multi_material:
		optimized_mesh = generate_optimized_level_mesh_multi_material()
	else:
		optimized_mesh = generate_optimized_level_mesh()
	
	# NOTE: Materials are intentionally kept on the mesh for .tres exports.
	# StandardMaterial3D is fully serialisable by ResourceSaver.
	var success = ResourceSaver.save(optimized_mesh, filepath)
	
	if success == OK:
		print("✓ Mesh exported successfully!")
		print("  Total tiles: ", tiles.size())
		
		var total_triangles = 0
		for i in range(optimized_mesh.get_surface_count()):
			var arrays = optimized_mesh.surface_get_arrays(i)
			total_triangles += arrays[Mesh.ARRAY_INDEX].size() / 3
		
		print("  Total triangles: ", total_triangles)
		print("  Surfaces: ", optimized_mesh.get_surface_count())
	else:
		push_error("Failed to save mesh: " + str(success))
	
	return optimized_mesh


func export_level_gltf(filepath: String) -> bool:
	"""
	Export the level as a glTF 2.0 file (.gltf or .glb) with all materials embedded.
	
	- .glb  → single binary file, textures embedded (recommended for sharing)
	- .gltf → human-readable JSON + separate texture files in the same folder
	
	Uses Godot's built-in GLTFDocument API so StandardMaterial3D properties
	(albedo colour, roughness, metallic, textures, etc.) are exported automatically.
	"""
	
	if tiles.is_empty():
		push_error("glTF export: no tiles to export")
		return false
	
	if not filepath.ends_with(".gltf") and not filepath.ends_with(".glb"):
		filepath += ".glb"
	
	print("\n=== glTF EXPORT START ===")
	print("Path: ", filepath)
	
	# ------------------------------------------------------------------ #
	# 1. Build combined multi-material mesh (materials already set)       #
	# ------------------------------------------------------------------ #
	var optimized_mesh = generate_optimized_level_mesh_multi_material()
	
	if optimized_mesh.get_surface_count() == 0:
		push_error("glTF export: mesh generation produced no surfaces")
		return false
	
	# ------------------------------------------------------------------ #
	# 2. Resolve per-tile palette materials onto surfaces                 #
	# ------------------------------------------------------------------ #
	_resolve_palette_materials_on_mesh(optimized_mesh)
	
	print("Surfaces to export: ", optimized_mesh.get_surface_count())
	for i in range(optimized_mesh.get_surface_count()):
		var mat = optimized_mesh.surface_get_material(i)
		var mat_label = ""
		if mat:
			mat_label = mat.resource_name if mat.resource_name != "" else "material"
		else:
			mat_label = "NO MATERIAL"
		print("  Surface ", i, ": ", mat_label)
	
	# ------------------------------------------------------------------ #
	# 3. Wrap in MeshInstance3D so GLTFDocument can traverse the scene    #
	# ------------------------------------------------------------------ #
	var mesh_instance = MeshInstance3D.new()
	mesh_instance.name = "ExportedLevel"
	mesh_instance.mesh = optimized_mesh
	
	var export_root = Node3D.new()
	export_root.name = "Scene"
	export_root.add_child(mesh_instance)
	mesh_instance.owner = export_root
	
	# ------------------------------------------------------------------ #
	# 4. Run the GLTFDocument export                                      #
	# ------------------------------------------------------------------ #
	var gltf_doc = GLTFDocument.new()
	var gltf_state = GLTFState.new()
	
	var append_err = gltf_doc.append_from_scene(export_root, gltf_state)
	if append_err != OK:
		push_error("glTF export: append_from_scene failed (error %d)" % append_err)
		export_root.free()
		return false
	
	var dir = filepath.get_base_dir()
	if dir != "" and dir != "res://" and dir != "user://":
		DirAccess.make_dir_recursive_absolute(dir)
	
	var write_err = gltf_doc.write_to_filesystem(gltf_state, filepath)
	export_root.free()
	
	if write_err != OK:
		push_error("glTF export: write_to_filesystem failed (error %d)" % write_err)
		return false
	
	var real_path = ProjectSettings.globalize_path(filepath)
	print("✓ glTF exported successfully!")
	print("  File: ", real_path)
	print("  Tiles: ", tiles.size())
	print("  Surfaces (materials): ", optimized_mesh.get_surface_count())
	print("=== glTF EXPORT END ===\n")
	return true


func _resolve_palette_materials_on_mesh(mesh: ArrayMesh) -> void:
	"""
	If tiles have been painted with palette materials, find the most-used
	palette material per mesh surface and apply it. Surfaces with no painted
	tiles keep the base material set by generate_optimized_level_mesh_multi_material().
	"""
	if not tile_map or not tile_map.material_palette_ref:
		return
	var palette = tile_map.material_palette_ref
	if not palette.has_method("get_material_at_index"):
		return
	
	# Count palette material usage per tile type
	var material_votes: Dictionary = {}
	for pos in tile_map.tile_materials:
		var material_index: int = tile_map.tile_materials[pos]
		if pos not in tiles:
			continue
		var tile_type = tiles[pos]
		if tile_type not in material_votes:
			material_votes[tile_type] = {}
		var votes = material_votes[tile_type]
		votes[material_index] = votes.get(material_index, 0) + 1
	
	if material_votes.is_empty():
		return
	
	var surface_tile_types = _build_surface_tile_type_map()
	
	for surface_idx in range(mesh.get_surface_count()):
		if surface_idx >= surface_tile_types.size():
			break
		var tile_type = surface_tile_types[surface_idx]
		if tile_type not in material_votes:
			continue
		var votes = material_votes[tile_type]
		var best_index = -1
		var best_count = 0
		for mat_idx in votes:
			if votes[mat_idx] > best_count:
				best_count = votes[mat_idx]
				best_index = mat_idx
		if best_index < 0:
			continue
		var palette_material = palette.get_material_at_index(best_index)
		if palette_material:
			mesh.surface_set_material(surface_idx, palette_material)


func _build_surface_tile_type_map() -> Array:
	"""
	Returns an Array where index == surface index and value == tile_type.
	Mirrors the surface-addition order in generate_optimized_level_mesh_multi_material().
	"""
	var map = []
	var tiles_by_type = {}
	for pos in tiles:
		var tile_type = tiles[pos]
		if tile_type not in tiles_by_type:
			tiles_by_type[tile_type] = []
		tiles_by_type[tile_type].append(pos)
	for tile_type in tiles_by_type:
		if tile_type in custom_meshes:
			var num_surfaces = custom_meshes[tile_type].get_surface_count()
			for _s in range(num_surfaces):
				map.append(tile_type)
		else:
			map.append(tile_type)
	return map


# ============================================================================
# CHUNKED EXPORT - NEW
# ============================================================================

func build_chunk_meshes(save_name: String, chunk_size: Vector3i = Vector3i(32, 32, 32),
						use_multi_material: bool = true, file_ext: String = "tres") -> Dictionary:
	"""Thread-safe: builds all chunk meshes and returns data needed for file I/O.

	Returns a Dictionary with:
	  "export_dir"  : String   - destination directory path
	  "file_ext"    : String   - normalised extension (no dot)
	  "is_gltf"     : bool
	  "chunks"      : Array[Dictionary]  each: { "name", "filepath", "mesh" }
	  "metadata"    : Dictionary         - chunk manifest data
	File I/O (ResourceSaver / GLTFDocument) must be done on the main thread.
	"""

	if tiles.is_empty():
		print("No tiles to export")
		return {}

	# Normalise extension (no leading dot)
	file_ext = file_ext.trim_prefix(".").to_lower()
	var is_gltf = (file_ext == "gltf" or file_ext == "glb")

	# Prepare export directory paths (creation happens on main thread later)
	var export_base = "user://exports/"
	var export_dir = export_base + "exported_level_" + save_name + "/"

	print("\n=== CHUNKED EXPORT — BUILDING MESHES ===")
	print("Save name: ", save_name)
	print("Format: ", file_ext)
	print("Export directory: ", export_dir)
	print("Chunk size: ", chunk_size)
	print("Total tiles: ", tiles.size())

	var bounds = _calculate_tile_bounds()
	print("Level bounds: ", bounds["min"], " to ", bounds["max"])

	var chunk_defs = _divide_into_chunks(bounds, chunk_size)
	print("Total chunks: ", chunk_defs.size())

	var built_chunks: Array = []
	for chunk in chunk_defs:
		var chunk_tiles = _get_tiles_in_chunk(chunk)
		if chunk_tiles.is_empty():
			continue

		var chunk_name = "chunk_%d_%d_%d" % [chunk["coord"].x, chunk["coord"].y, chunk["coord"].z]
		var chunk_filepath = export_dir + chunk_name + "." + file_ext

		print("  Building chunk [%d, %d, %d]: %d tiles" % [
			chunk["coord"].x, chunk["coord"].y, chunk["coord"].z, chunk_tiles.size()
		])

		var chunk_mesh = _generate_chunk_mesh(chunk_tiles, chunk["min"], use_multi_material)
		built_chunks.append({ "name": chunk_name, "filepath": chunk_filepath, "mesh": chunk_mesh })

	var metadata = {
		"save_name": save_name,
		"chunk_size": {"x": chunk_size.x, "y": chunk_size.y, "z": chunk_size.z},
		"bounds_min": {"x": bounds["min"].x, "y": bounds["min"].y, "z": bounds["min"].z},
		"bounds_max": {"x": bounds["max"].x, "y": bounds["max"].y, "z": bounds["max"].z},
		"total_tiles": tiles.size(),
		"total_chunks": built_chunks.size(),
		"export_date": Time.get_datetime_string_from_system()
	}

	print("=== CHUNK MESH BUILD COMPLETE ===\n")
	return {
		"export_dir": export_dir,
		"file_ext": file_ext,
		"is_gltf": is_gltf,
		"chunks": built_chunks,
		"metadata": metadata
	}


func export_level_chunked(save_name: String, chunk_size: Vector3i = Vector3i(32, 32, 32),
						  use_multi_material: bool = true, file_ext: String = "tres"):
	"""Convenience wrapper — builds and saves all chunks on the calling thread.
	Only safe to call from the main thread. For background export use
	build_chunk_meshes() on a worker thread then _finish_export_chunked() on main.
	"""
	var data = build_chunk_meshes(save_name, chunk_size, use_multi_material, file_ext)
	if data.is_empty():
		return
	_save_chunk_data(data)


func _save_chunk_data(data: Dictionary) -> void:
	"""Main-thread only: writes all chunk meshes and the metadata file to disk."""
	var export_dir: String = data["export_dir"]
	var is_gltf: bool = data["is_gltf"]
	var file_ext: String = data["file_ext"]

	DirAccess.make_dir_recursive_absolute("user://exports/")
	DirAccess.make_dir_recursive_absolute(export_dir)

	print("\n=== CHUNKED EXPORT — SAVING FILES ===")

	for chunk in data["chunks"]:
		var chunk_name: String = chunk["name"]
		var chunk_filepath: String = chunk["filepath"]
		var chunk_mesh: ArrayMesh = chunk["mesh"]

		if is_gltf:
			var mesh_instance = MeshInstance3D.new()
			mesh_instance.name = chunk_name
			mesh_instance.mesh = chunk_mesh
			var export_root = Node3D.new()
			export_root.name = "Scene"
			export_root.add_child(mesh_instance)
			mesh_instance.owner = export_root
			var gltf_doc = GLTFDocument.new()
			var gltf_state = GLTFState.new()
			var append_err = gltf_doc.append_from_scene(export_root, gltf_state)
			export_root.free()
			if append_err != OK:
				push_error("    ✗ glTF append failed for chunk: " + str(append_err))
				continue
			var write_err = gltf_doc.write_to_filesystem(gltf_state, chunk_filepath)
			if write_err == OK:
				print("    ✓ Saved: ", chunk_filepath)
			else:
				push_error("    ✗ glTF write failed for chunk: " + str(write_err))
		else:
			for i in range(chunk_mesh.get_surface_count()):
				chunk_mesh.surface_set_material(i, null)
			var success = ResourceSaver.save(chunk_mesh, chunk_filepath)
			if success == OK:
				print("    ✓ Saved: ", chunk_filepath)
			else:
				push_error("    ✗ Failed to save chunk: " + str(success))

	# Save metadata file
	var metadata_file = FileAccess.open(export_dir + "metadata.json", FileAccess.WRITE)
	if metadata_file:
		metadata_file.store_string(JSON.stringify(data["metadata"], "\t"))
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
	"""Generate optimized mesh for a single chunk.

	Keeps the full tiles dictionary intact during generation so that neighbor
	lookups at chunk boundaries correctly see adjacent tiles and cull shared
	faces. Only tiles present in chunk_tiles emit actual geometry.
	"""

	# Swap in a restricted emit-set without touching the full tiles dict.
	# mesh_generator.get_neighbors() reads from tile_map.tiles (the full set),
	# while we override the local tiles reference used by the surface-building
	# loops so they only iterate over this chunk's positions.
	var original_tiles = tiles
	tiles = chunk_tiles

	# Patch tile_map.tiles to the FULL set so get_neighbors() sees everything,
	# but the optimizer loops only visit chunk_tiles positions.
	var original_tilemap_tiles = tile_map.tiles
	tile_map.tiles = original_tiles  # full set for neighbor lookups

	var chunk_mesh: ArrayMesh
	if use_multi_material:
		chunk_mesh = generate_optimized_level_mesh_multi_material()
	else:
		chunk_mesh = generate_optimized_level_mesh()

	# Restore both references
	tiles = original_tiles
	tile_map.tiles = original_tilemap_tiles

	return chunk_mesh
