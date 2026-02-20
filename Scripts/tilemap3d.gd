class_name TileMap3D extends RefCounted


# ============================================================================
# CORE DATA
# ============================================================================
var tiles = {}  # Vector3i -> tile_type
var tile_meshes = {}  # Vector3i -> MeshInstance3D
var custom_meshes = {}  # tile_type -> ArrayMesh (custom loaded meshes)
var custom_materials: Dictionary = {}  # tile_type -> Array[Material]
var grid_size: float = 1.0
var parent_node: Node3D
var offset_provider: Callable
var tile_rotations: Dictionary = {}  # Vector3i -> float (degrees)
var tile_materials: Dictionary = {}  # Vector3i -> int (material_index)
var tile_step_counts: Dictionary = {}

# ============================================================================
# COMPONENTS
# ============================================================================
var top_plane_mesh_instance: MeshInstance3D = null  # Single merged mesh for all exposed tops


var mesh_loader: MeshLoader
var mesh_generator: MeshGenerator
var mesh_editor: MeshEditor
var material_manager: MaterialManager
var tile_manager: TileManager
var mesh_optimizer: MeshOptimizer
var material_palette_ref = null  # Reference to material palette for applying materials

# ============================================================================
# INITIALIZATION
# ============================================================================

func _init(grid_sz: float = 1.0):
	grid_size = grid_sz
	
	# Initialize all components
	mesh_editor = MeshEditor.new()
	mesh_generator = MeshGenerator.new()
	mesh_loader = MeshLoader.new()
	tile_manager = TileManager.new()
	mesh_optimizer = MeshOptimizer.new()
	material_manager = MaterialManager.new()
	
	print("TileMap3D: Components initialized")

# Setup components after parent_node is set
func _setup_components():
	if not parent_node:
		push_error("Cannot setup components: parent_node is null")
		return
	
	# Setup in dependency order
	mesh_editor.setup(self, custom_meshes, tiles)
	mesh_generator.setup(self, custom_meshes, tiles, grid_size)
	mesh_loader.setup(custom_meshes, custom_materials, grid_size, mesh_editor)
	tile_manager.setup(self, tiles, tile_meshes, custom_meshes, grid_size, parent_node, mesh_generator)
	mesh_optimizer.setup(self, tiles, custom_meshes, mesh_generator, custom_materials)

	material_manager.setup(self, custom_meshes, custom_materials, tiles)
	
	print("TileMap3D: Components setup complete")

# ============================================================================
# CONFIGURATION
# ============================================================================

func set_parent(node: Node3D):
	parent_node = node
	_setup_components()
	# Create the top plane mesh instance
	top_plane_mesh_instance = MeshInstance3D.new()
	top_plane_mesh_instance.name = "TopPlaneMesh"
	parent_node.add_child(top_plane_mesh_instance)


func rebuild_top_plane_mesh():
	if not top_plane_mesh_instance:
		return

	if tiles.is_empty():
		top_plane_mesh_instance.mesh = null
		return

	var top_y_offset: float = 0.99948
	var top_face_inset: float = 0.070246
	var inset = top_face_inset

	# Group quads by their effective top Material object
	# Key: Material reference, Value: {verts, normals, uvs, indices, idx, material}
	var quads_by_material: Dictionary = {}

	for pos in tiles.keys():
		var neighbors = tile_manager.get_neighbors(pos)
		if neighbors[MeshGenerator.NeighborDir.UP] != -1:
			continue

		var ND = MeshGenerator.NeighborDir
		var has_north = neighbors[ND.NORTH] != -1
		var has_south = neighbors[ND.SOUTH] != -1
		var has_east  = neighbors[ND.EAST]  != -1
		var has_west  = neighbors[ND.WEST]  != -1

		if (not has_north and not has_west) or (not has_north and not has_east) or \
		   (not has_south and not has_west) or (not has_south and not has_east):
			continue

		# Resolve the top material: per-tile palette override takes priority
		var top_mat: Material = null
		var palette_index = tile_materials.get(pos, -1)
		if palette_index >= 0 and material_palette_ref:
			top_mat = material_palette_ref.get_material_for_surface(palette_index, 0)
		if top_mat == null:
			top_mat = get_custom_material(tiles[pos], 0)

		# Use the material's RID as grouping key (null materials get grouped together)
		var group_key = top_mat.get_rid() if top_mat else "null"
		if group_key not in quads_by_material:
			quads_by_material[group_key] = {
				"verts": PackedVector3Array(),
				"normals": PackedVector3Array(),
				"uvs": PackedVector2Array(),
				"indices": PackedInt32Array(),
				"idx": 0,
				"material": top_mat
			}
		var b = quads_by_material[group_key]

		var world_pos = tile_manager.grid_to_world(pos)
		var s = grid_size
		var y = world_pos.y + top_y_offset
		var xL = world_pos.x
		var xR = world_pos.x + s
		var zN = world_pos.z
		var zS = world_pos.z + s

		var x0 = xL + (0.0 if has_west  else inset)
		var x1 = xR - (0.0 if has_east  else inset)
		var z0 = zN + (0.0 if has_north else inset)
		var z1 = zS - (0.0 if has_south else inset)

		var base = b["idx"]
		b["verts"].append(Vector3(x0, y, z0))
		b["verts"].append(Vector3(x1, y, z0))
		b["verts"].append(Vector3(x1, y, z1))
		b["verts"].append(Vector3(x0, y, z1))
		b["normals"].append(Vector3.UP)
		b["normals"].append(Vector3.UP)
		b["normals"].append(Vector3.UP)
		b["normals"].append(Vector3.UP)
		b["uvs"].append(Vector2((x0 - xL) / s, (z0 - zN) / s))
		b["uvs"].append(Vector2((x1 - xL) / s, (z0 - zN) / s))
		b["uvs"].append(Vector2((x1 - xL) / s, (z1 - zN) / s))
		b["uvs"].append(Vector2((x0 - xL) / s, (z1 - zN) / s))
		b["indices"].append(base);     b["indices"].append(base + 1); b["indices"].append(base + 2)
		b["indices"].append(base);     b["indices"].append(base + 2); b["indices"].append(base + 3)
		b["idx"] += 4

	if quads_by_material.is_empty():
		top_plane_mesh_instance.mesh = null
		return

	var new_mesh = ArrayMesh.new()
	var surface_idx = 0
	for group_key in quads_by_material:
		var b = quads_by_material[group_key]
		var surface_array = []
		surface_array.resize(Mesh.ARRAY_MAX)
		surface_array[Mesh.ARRAY_VERTEX] = b["verts"]
		surface_array[Mesh.ARRAY_NORMAL] = b["normals"]
		surface_array[Mesh.ARRAY_TEX_UV] = b["uvs"]
		surface_array[Mesh.ARRAY_INDEX]  = b["indices"]
		new_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface_array)
		if b["material"]:
			new_mesh.surface_set_material(surface_idx, b["material"])
		surface_idx += 1

	top_plane_mesh_instance.mesh = new_mesh


func set_offset_provider(provider: Callable):
	offset_provider = provider


func set_material_palette_reference(palette):
	"""Set reference to material palette for applying materials to tiles"""
	material_palette_ref = palette


func get_offset_for_y(y_level: int) -> Vector2:
	if offset_provider.is_valid():
		return offset_provider.call(y_level)
	return Vector2.ZERO

# ============================================================================
# MESH LOADING (Delegate to MeshLoader)
# ============================================================================

func load_obj_for_tile_type(tile_type: int, obj_path: String) -> bool:
	return mesh_loader.load_obj_for_tile_type(tile_type, obj_path)


func extend_mesh_to_boundaries(tile_type: int, threshold: float = 0.15) -> bool:
	return mesh_loader.extend_mesh_to_boundaries(tile_type, threshold)


func flip_mesh_normals(tile_type: int) -> bool:
	return mesh_loader.flip_mesh_normals(tile_type)


func align_mesh_to_grid(tile_type: int) -> bool:
	return mesh_loader.align_mesh_to_grid(tile_type)

# ============================================================================
# MESH EDITING (Delegate to MeshEditor)
# ============================================================================

func get_mesh_data(tile_type: int) -> Dictionary:
	return mesh_editor.get_mesh_data(tile_type)


func edit_mesh_vertices(tile_type: int, new_vertices: PackedVector3Array) -> bool:
	return mesh_editor.edit_mesh_vertices(tile_type, new_vertices)


func transform_vertex(tile_type: int, vertex_index: int, new_position: Vector3) -> bool:
	return mesh_editor.transform_vertex(tile_type, vertex_index, new_position)


func scale_mesh(tile_type: int, scale: Vector3) -> bool:
	return mesh_editor.scale_mesh(tile_type, scale)


func recalculate_normals(tile_type: int) -> bool:
	return mesh_editor.recalculate_normals(tile_type)

# ============================================================================
# MATERIAL MANAGEMENT (Delegate to MaterialManager)
# ============================================================================

func set_custom_material(tile_type: int, surface_index: int, material: StandardMaterial3D) -> bool:
	return material_manager.set_custom_material(tile_type, surface_index, material)


func get_surface_count(tile_type: int) -> int:
	return material_manager.get_surface_count(tile_type)


func get_custom_material(tile_type: int, surface_index: int) -> Material:
	return material_manager.get_custom_material(tile_type, surface_index)


func create_custom_material(albedo_color: Color, metallic: float = 0.0, 
							roughness: float = 1.0, emission: Color = Color.BLACK) -> StandardMaterial3D:
	return material_manager.create_custom_material(albedo_color, metallic, roughness, emission)

# ============================================================================
# TILE MANAGEMENT (Delegate to TileManager)
# ============================================================================

func world_to_grid(pos: Vector3) -> Vector3i:
	return tile_manager.world_to_grid(pos)


func grid_to_world(pos: Vector3i) -> Vector3:
	return tile_manager.grid_to_world(pos)


func place_tile(pos: Vector3i, tile_type: int):
	tile_manager.place_tile(pos, tile_type)


func place_tile_with_material(pos: Vector3i, tile_type: int, material_index: int, palette_ref):
	"""Place a tile and apply a material to it"""
	tile_manager.place_tile(pos, tile_type)
	apply_material_to_tile(pos, material_index, palette_ref)


func apply_material_to_tile(pos: Vector3i, material_index: int, palette_ref):
	"""Apply a material to an existing tile"""
	if pos not in tiles:
		return
	
	# Store material index
	tile_materials[pos] = material_index
	
	# Get material from palette
	var material = palette_ref.get_material_at_index(material_index)
	
	# Apply to mesh instance if it exists
	if pos in tile_meshes and material:
		tile_meshes[pos].set_surface_override_material(0, material)
	
	rebuild_top_plane_mesh()


func get_tile_material_index(pos: Vector3i) -> int:
	"""Get the material index for a tile at the given position"""
	return tile_materials.get(pos, -1)


func remove_tile(pos: Vector3i):
	tile_manager.remove_tile(pos)
	# Clean up material data
	if pos in tile_materials:
		tile_materials.erase(pos)
	rebuild_top_plane_mesh()


func has_tile(pos: Vector3i) -> bool:
	return tile_manager.has_tile(pos)


func get_tile_type(pos: Vector3i) -> int:
	return tile_manager.get_tile_type(pos)


func update_tile_mesh(pos: Vector3i):
	tile_manager.update_tile_mesh(pos)


func get_neighbors(pos: Vector3i) -> Dictionary:
	return tile_manager.get_neighbors(pos)


func refresh_y_level(y_level: int):
	for pos in tiles.keys():
		if pos.y == y_level:
			update_tile_mesh(pos)
	for pos in tiles.keys():
		if pos.y == y_level + 1 or pos.y == y_level - 1:
			update_tile_mesh(pos)

# ============================================================================
# MESH GENERATION (Delegate to MeshGenerator)
# ============================================================================

func generate_custom_tile_mesh(pos: Vector3i, tile_type: int, neighbors: Dictionary, rotation_degrees: float = 0.0) -> ArrayMesh:
	return mesh_generator.generate_custom_tile_mesh(pos, tile_type, neighbors, rotation_degrees)


func generate_tile_mesh(tile_type: int, neighbors: Dictionary) -> ArrayMesh:
	return mesh_generator.generate_tile_mesh(tile_type, neighbors)


func should_render_vertical_face(current_pos: Vector3i, neighbor_pos: Vector3i) -> bool:
	return mesh_generator.should_render_vertical_face(current_pos, neighbor_pos)

# ============================================================================
# OPTIMIZATION & EXPORT (Delegate to MeshOptimizer)
# ============================================================================

func generate_optimized_level_mesh() -> ArrayMesh:
	return mesh_optimizer.generate_optimized_level_mesh()


func generate_optimized_level_mesh_multi_material() -> ArrayMesh:
	return mesh_optimizer.generate_optimized_level_mesh_multi_material()


func export_level_to_file(filepath: String, use_multi_material: bool = true):
	return mesh_optimizer.export_level_to_file(filepath, use_multi_material)


func export_level_gltf(filepath: String) -> bool:
	return mesh_optimizer.export_level_gltf(filepath)


func export_level_chunked(save_name: String, chunk_size: Vector3i = Vector3i(32, 32, 32),
						  use_multi_material: bool = true, file_ext: String = "tres"):
	return mesh_optimizer.export_level_chunked(save_name, chunk_size, use_multi_material, file_ext)


func tick() -> void:
	tile_manager.tick()


func cleanup() -> void:
	tile_manager.cleanup()


# ============================================================================
# Rotation methods (delegates to TileManager)
# ============================================================================

func get_tile_rotation(pos: Vector3i) -> float:
	"""Get the rotation of a tile in degrees (0-360)"""
	return tile_rotations.get(pos, 0.0)

func set_tile_rotation(pos: Vector3i, rotation_degrees: float):
	if pos not in tiles:
		return
	
	tile_rotations[pos] = rotation_degrees
	tile_manager.update_tile_mesh(pos)


# ============================================================================
# BATCH MODE OPERATIONS
# ============================================================================

func set_batch_mode(enabled: bool):
	"""Enable or disable batch mode for mass tile operations"""
	tile_manager.set_batch_mode(enabled)


func flush_batch_updates():
	"""Manually flush all pending tile updates (only needed if batch mode is still enabled)"""
	tile_manager.flush_batch_updates()

# ============================================================================
# DEBUG HELPERS
# ============================================================================

func print_corner_debug():
	"""Print corner culling debug summary - call after placing tiles"""
	tile_manager.print_corner_debug()
