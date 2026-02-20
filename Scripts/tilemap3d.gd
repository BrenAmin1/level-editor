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
var mesh_loader: MeshLoader
var mesh_generator: MeshGenerator
var mesh_editor: MeshEditor
var material_manager: MaterialManager
var tile_manager: TileManager
var mesh_optimizer: MeshOptimizer
var material_palette_ref = null  # Reference to material palette for applying materials

# ============================================================================
# TOP PLANE — per-tile MeshInstance3D nodes
# ============================================================================
# One MeshInstance3D per tile that has a visible top quad, stored in
# _top_plane_nodes. All nodes that share a material reference the same
# QuadMesh resource (stored in _top_plane_quad_meshes keyed by material RID
# string) so Godot's renderer can batch them into a single draw call per
# material group — equivalent to the old merged ArrayMesh but with O(1)
# placement cost instead of O(n).
#
# Layout note: QuadMesh with FACE_Y orientation is a flat horizontal plane.
# We set its size per-node via set_surface_override_material so each node can
# carry its own material while sharing the mesh resource for batching.
# The size is baked into the node's scale instead (see _flush_top_plane_dirty).
var _top_plane_nodes: Dictionary = {}        # Vector3i -> MeshInstance3D
var _top_plane_quad_mesh: QuadMesh = null    # Single shared QuadMesh (unit size, scaled per node)
var _top_plane_container: Node3D = null      # Parent node — keeps scene tree tidy

var _top_plane_dirty: bool = false
var _top_plane_dirty_positions: Dictionary = {}  # Vector3i -> true

# Quad geometry constants — must match the original merged mesh values exactly
const _TOP_Y_OFFSET: float = 0.99948
const _TOP_FACE_INSET: float = 0.070246

# ============================================================================
# INITIALIZATION
# ============================================================================

func _init(grid_sz: float = 1.0):
	grid_size = grid_sz

	mesh_editor = MeshEditor.new()
	mesh_generator = MeshGenerator.new()
	mesh_loader = MeshLoader.new()
	tile_manager = TileManager.new()
	mesh_optimizer = MeshOptimizer.new()
	material_manager = MaterialManager.new()

	# One shared unit-size QuadMesh; individual nodes are scaled to their quad size
	_top_plane_quad_mesh = QuadMesh.new()
	_top_plane_quad_mesh.orientation = PlaneMesh.FACE_Y
	_top_plane_quad_mesh.size = Vector2(1.0, 1.0)

	print("TileMap3D: Components initialized")


func _setup_components():
	if not parent_node:
		push_error("Cannot setup components: parent_node is null")
		return

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
	_top_plane_container = Node3D.new()
	_top_plane_container.name = "TopPlaneQuads"
	parent_node.add_child(_top_plane_container)


func _request_top_plane_rebuild():
	if not _top_plane_dirty:
		_top_plane_dirty = true
		call_deferred("_deferred_rebuild_top_plane")


func _deferred_rebuild_top_plane():
	_top_plane_dirty = false
	if _top_plane_dirty_positions.is_empty():
		return
	_flush_top_plane_dirty()


# Mark a placed/removed position and its 4 cardinal neighbors dirty.
# Cardinals matter because each neighbor's inset edges depend on whether the
# adjacent tile exists.
func _mark_top_plane_dirty_around(pos: Vector3i):
	_top_plane_dirty_positions[pos] = true
	for offset in [Vector3i(1,0,0), Vector3i(-1,0,0), Vector3i(0,0,1), Vector3i(0,0,-1)]:
		_top_plane_dirty_positions[pos + offset] = true


# Process only the dirty positions — O(dirty) not O(all tiles).
func _flush_top_plane_dirty():
	if not _top_plane_container:
		return

	var ND = MeshGenerator.NeighborDir
	var inset = _TOP_FACE_INSET

	for pos in _top_plane_dirty_positions.keys():
		# Tile removed — destroy its quad node
		if pos not in tiles:
			_remove_top_plane_node(pos)
			continue

		var neighbors = tile_manager.get_neighbors(pos)

		# Stairs are 3-D geometry — never get a flat top quad
		if tiles[pos] == 5:  # TILE_TYPE_STAIRS
			_remove_top_plane_node(pos)
			continue

		# Covered from above — no top quad
		if neighbors[ND.UP] != -1:
			_remove_top_plane_node(pos)
			continue

		var has_north = neighbors[ND.NORTH] != -1
		var has_south = neighbors[ND.SOUTH] != -1
		var has_east  = neighbors[ND.EAST]  != -1
		var has_west  = neighbors[ND.WEST]  != -1

		# Exposed corner tile — skip (matches original logic)
		if (not has_north and not has_west) or (not has_north and not has_east) or \
		   (not has_south and not has_west) or (not has_south and not has_east):
			_remove_top_plane_node(pos)
			continue

		# Resolve material: per-tile palette override takes priority
		var top_mat: Material = null
		var palette_index = tile_materials.get(pos, -1)
		if palette_index >= 0 and material_palette_ref:
			top_mat = material_palette_ref.get_material_for_surface(palette_index, 0)
		if top_mat == null:
			top_mat = get_custom_material(tiles[pos], 0)

		# Compute quad bounds
		var world_pos = tile_manager.grid_to_world(pos)
		var s = grid_size
		var x0 = world_pos.x + (0.0 if has_west  else inset)
		var x1 = world_pos.x + s - (0.0 if has_east  else inset)
		var z0 = world_pos.z + (0.0 if has_north else inset)
		var z1 = world_pos.z + s - (0.0 if has_south else inset)

		var quad_w = x0 + (x1 - x0) * 0.5   # center x
		var quad_z = z0 + (z1 - z0) * 0.5   # center z
		var quad_y = world_pos.y + _TOP_Y_OFFSET

		# Get or create the MeshInstance3D for this tile
		var mi: MeshInstance3D
		if pos in _top_plane_nodes:
			mi = _top_plane_nodes[pos]
		else:
			mi = MeshInstance3D.new()
			mi.mesh = _top_plane_quad_mesh
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			_top_plane_container.add_child(mi)
			_top_plane_nodes[pos] = mi

		# Scale encodes the quad's width (X) and depth (Z); Y scale is irrelevant
		mi.scale = Vector3(x1 - x0, 1.0, z1 - z0)
		mi.position = Vector3(quad_w, quad_y, quad_z)
		mi.set_surface_override_material(0, top_mat)

	_top_plane_dirty_positions.clear()


func _remove_top_plane_node(pos: Vector3i):
	if pos in _top_plane_nodes:
		_top_plane_nodes[pos].queue_free()
		_top_plane_nodes.erase(pos)


# Full rebuild from scratch — used after a batch load where the entire level
# changes at once.
func rebuild_top_plane_mesh():
	if not _top_plane_container:
		return

	# Destroy all existing quad nodes
	for pos in _top_plane_nodes.keys():
		_top_plane_nodes[pos].queue_free()
	_top_plane_nodes.clear()
	_top_plane_dirty_positions.clear()

	if tiles.is_empty():
		return

	# Mark every tile dirty and flush in one pass
	for pos in tiles.keys():
		_top_plane_dirty_positions[pos] = true
	_flush_top_plane_dirty()


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
	if not tile_manager.batch_mode:
		_mark_top_plane_dirty_around(pos)
		# The tile directly below now has a tile above it — its top quad must be removed
		var below = pos + Vector3i(0, -1, 0)
		if below in tiles:
			_mark_top_plane_dirty_around(below)
		_request_top_plane_rebuild()


func place_tile_with_material(pos: Vector3i, tile_type: int, material_index: int, palette_ref):
	"""Place a tile and apply a material to it"""
	tile_manager.place_tile(pos, tile_type)
	apply_material_to_tile(pos, material_index, palette_ref)
	# apply_material_to_tile already triggers _request_top_plane_rebuild


func apply_material_to_tile(pos: Vector3i, material_index: int, palette_ref):
	"""Apply a material to an existing tile"""
	if pos not in tiles:
		return

	tile_materials[pos] = material_index

	var material = palette_ref.get_material_at_index(material_index)

	# Update the main tile mesh — override ALL surfaces so cached meshes with a
	# different tile's baked side/bottom material don't bleed through.
	if pos in tile_meshes and material:
		var mi = tile_meshes[pos]
		if mi.mesh:
			for surf_idx in range(mi.mesh.get_surface_count()):
				mi.set_surface_override_material(surf_idx, material)

	# Update the top-plane node directly — no deferred rebuild needed at all,
	# just swap the material override on the existing node
	if pos in _top_plane_nodes:
		_top_plane_nodes[pos].set_surface_override_material(0, material)
	elif not tile_manager.batch_mode:
		# Node doesn't exist yet — mark dirty so it gets created on next flush
		_top_plane_dirty_positions[pos] = true
		_request_top_plane_rebuild()


func get_tile_material_index(pos: Vector3i) -> int:
	"""Get the material index for a tile at the given position"""
	return tile_materials.get(pos, -1)


func remove_tile(pos: Vector3i):
	tile_manager.remove_tile(pos)
	if pos in tile_materials:
		tile_materials.erase(pos)
	_mark_top_plane_dirty_around(pos)
	# The tile directly below now has no tile above it — mark it so it gets a top quad
	var below = pos + Vector3i(0, -1, 0)
	if below in tiles:
		_mark_top_plane_dirty_around(below)
	_request_top_plane_rebuild()


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
# ROTATION (Delegate to TileManager)
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
	# Only set the default top-plane callback if the caller (e.g. level_manager)
	# hasn't already registered a richer one that handles materials + rotations too.
	if not tile_manager.flush_completed_callback.is_valid():
		tile_manager.flush_completed_callback = func(): rebuild_top_plane_mesh()
	tile_manager.flush_batch_updates()

# ============================================================================
# DEBUG HELPERS
# ============================================================================

func print_corner_debug():
	"""Print corner culling debug summary - call after placing tiles"""
	tile_manager.print_corner_debug()
