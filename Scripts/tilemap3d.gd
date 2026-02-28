class_name TileMap3D extends RefCounted


# ============================================================================
# CORE DATA
# ============================================================================
var tiles: Dictionary[Vector3i, int] = {}
var tile_meshes: Dictionary[Vector3i, MeshInstance3D] = {}
var custom_meshes: Dictionary[int, ArrayMesh] = {}
var custom_materials: Dictionary[int, Array] = {}  # Array[Material] per tile_type
var grid_size: float = 1.0
var parent_node: Node3D
var offset_provider: Callable
var tile_rotations: Dictionary[Vector3i, float] = {}
var tile_materials: Dictionary[Vector3i, int] = {}
var tile_step_counts: Dictionary[Vector3i, int] = {}

# ============================================================================
# COMPONENTS
# ============================================================================
var mesh_loader: MeshLoader
var mesh_generator: MeshGenerator
var mesh_editor: MeshEditor
var material_manager: MaterialManager
var tile_manager: TileManager
var mesh_optimizer: MeshOptimizer
var glb_exporter: GlbExporter
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
var _top_plane_nodes: Dictionary[Vector3i, MeshInstance3D] = {}
var _top_plane_container: Node3D = null

var _top_plane_dirty: bool = false
var _top_plane_dirty_positions: Dictionary[Vector3i, bool] = {}

# Top-plane geometry constants.
# _TOP_Y_OFFSET    : gap above the tile top face (world_pos.y + grid_size + this).
# _TOP_CORNER_INSET: inset only on FREE corners (both adjacent cardinals absent).
#   Shared edges remain flush — no gaps between adjacent tiles.
const _TOP_Y_OFFSET: float = 0.0001
const _TOP_CORNER_INSET: float = 0.070246

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
	glb_exporter   = GlbExporter.new()
	material_manager = MaterialManager.new()

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
	glb_exporter.setup(self, mesh_optimizer)
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
	# Reset the flag BEFORE flushing so that any new dirty marks added during
	# the flush (or between frames) correctly re-queue another deferred call.
	# Without this, the flag stays true after flush, blocking future rebuilds.
	_top_plane_dirty = false
	if _top_plane_dirty_positions.is_empty():
		return
	_flush_top_plane_dirty()
	# If new positions were dirtied during the flush, queue another pass.
	if not _top_plane_dirty_positions.is_empty():
		_request_top_plane_rebuild()


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

	for pos in _top_plane_dirty_positions.keys():
		# Tile removed — destroy its overlay node
		if pos not in tiles:
			_remove_top_plane_node(pos)
			continue

		var neighbors = tile_manager.get_neighbors(pos)

		# Stairs are 3-D geometry — never get a flat top overlay
		if tiles[pos] == MeshGenerator.TILE_TYPE_STAIRS:
			_remove_top_plane_node(pos)
			continue

		# Covered from above — no top overlay
		if neighbors[ND.UP] != -1:
			_remove_top_plane_node(pos)
			continue

		# Resolve material: per-tile palette override takes priority
		var top_mat: Material = null
		var palette_index = int(tile_materials.get(pos, -1))
		if palette_index >= 0 and material_palette_ref:
			top_mat = material_palette_ref.get_material_for_surface(palette_index, 0)
		if top_mat == null:
			top_mat = get_custom_material(tiles[pos], 0)

		var new_mesh = _build_top_polygon_mesh(pos, neighbors)

		var mi: MeshInstance3D
		if pos in _top_plane_nodes:
			mi = _top_plane_nodes[pos]
		else:
			mi = MeshInstance3D.new()
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			_top_plane_container.add_child(mi)
			_top_plane_nodes[pos] = mi

		mi.mesh = new_mesh
		mi.position = Vector3.ZERO
		mi.scale = Vector3.ONE
		mi.set_surface_override_material(0, top_mat)

	_top_plane_dirty_positions.clear()


# Build an ArrayMesh for the top-plane overlay of a single tile.
# Per-corner rule:
#   FLUSH  — edge is at the full grid cell boundary when that cardinal has a neighbor.
#             Shared edges must be gap-free.
#   INSET  — corner is pulled in by _TOP_CORNER_INSET only when BOTH adjacent
#             cardinals are absent, matching the bulge mesh top-face boundary.
func _build_top_polygon_mesh(pos: Vector3i, neighbors: Dictionary) -> ArrayMesh:
	var ND  = MeshGenerator.NeighborDir
	var s   = grid_size
	var ci  = _TOP_CORNER_INSET
	var wp  = tile_manager.grid_to_world(pos)
	var y   = wp.y + s + _TOP_Y_OFFSET

	var has_north = neighbors[ND.NORTH] != -1
	var has_south = neighbors[ND.SOUTH] != -1
	var has_east  = neighbors[ND.EAST]  != -1
	var has_west  = neighbors[ND.WEST]  != -1

	# Each corner insets only when BOTH of its adjacent cardinals are absent
	var x_nw = wp.x +     (0.0 if has_west  else ci)
	var z_nw = wp.z +     (0.0 if has_north else ci)
	var x_ne = wp.x + s - (0.0 if has_east  else ci)
	var z_ne = wp.z +     (0.0 if has_north else ci)
	var x_se = wp.x + s - (0.0 if has_east  else ci)
	var z_se = wp.z + s - (0.0 if has_south else ci)
	var x_sw = wp.x +     (0.0 if has_west  else ci)
	var z_sw = wp.z + s - (0.0 if has_south else ci)

	var verts   = PackedVector3Array()
	var normals = PackedVector3Array()
	var uvs     = PackedVector2Array()
	var indices = PackedInt32Array()

	verts.append_array([
		Vector3(x_nw, y, z_nw), Vector3(x_ne, y, z_ne),
		Vector3(x_se, y, z_se), Vector3(x_sw, y, z_sw),
	])
	for _i in 4:
		normals.append(Vector3.UP)
	uvs.append_array([
		Vector2((x_nw - wp.x) / s, (z_nw - wp.z) / s),
		Vector2((x_ne - wp.x) / s, (z_ne - wp.z) / s),
		Vector2((x_se - wp.x) / s, (z_se - wp.z) / s),
		Vector2((x_sw - wp.x) / s, (z_sw - wp.z) / s),
	])
	indices.append_array([0, 1, 2,  0, 2, 3])

	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX]  = indices
	var mesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


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
# PALETTE MATERIAL HELPERS
# ============================================================================

# Apply palette overrides to ALL surface roles (TOP=0, SIDES=1, BOTTOM=2).
# Surfaces are identified by their name (the string of their SurfaceRole int),
# set at mesh-build time, so this is safe regardless of surface array index.
# surface_materials: [top_mat, sides_mat, bottom_mat] — null entries are skipped.
static func apply_palette_materials_to_mesh(mi: MeshInstance3D, surface_materials: Array) -> void:
	var mesh_res = mi.mesh
	if not mesh_res:
		return
	for surf_idx in range(mesh_res.get_surface_count()):
		var role = mesh_res.surface_get_name(surf_idx).to_int()
		if role >= 0 and role < surface_materials.size() and surface_materials[role] != null:
			mi.set_surface_override_material(surf_idx, surface_materials[role])


# Convenience wrapper — TOP surface only (for the top-plane overlay node).
static func apply_palette_material_to_mesh(mi: MeshInstance3D, top_mat: Material) -> void:
	apply_palette_materials_to_mesh(mi, [top_mat, null, null])

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
		# If this position had a material entry before it was removed, re-apply it
		# now so the tile does not lose its palette assignment after erase-repaint.
		if pos in tile_materials and material_palette_ref:
			var mat_idx   = int(tile_materials[pos])
			var top_mat   = material_palette_ref.get_material_for_surface(mat_idx, 0)
			var sides_mat = material_palette_ref.get_material_for_surface(mat_idx, 1)
			var bot_mat   = material_palette_ref.get_material_for_surface(mat_idx, 2)
			if pos in tile_meshes:
				apply_palette_materials_to_mesh(tile_meshes[pos], [top_mat, sides_mat, bot_mat])

		_mark_top_plane_dirty_around(pos)

		var below = pos + Vector3i(0, -1, 0)
		if below in tiles:
			_mark_top_plane_dirty_around(below)

		for diag in [Vector3i(1,0,1), Vector3i(1,0,-1), Vector3i(-1,0,1), Vector3i(-1,0,-1)]:
			var diag_pos = pos + diag
			if diag_pos in tiles:
				_top_plane_dirty_positions[diag_pos] = true

		if below in tiles:
			for cardinal in [Vector3i(1,0,0), Vector3i(-1,0,0), Vector3i(0,0,1), Vector3i(0,0,-1)]:
				var below_neighbor = below + cardinal
				if below_neighbor in tiles:
					_top_plane_dirty_positions[below_neighbor] = true

		_flush_top_plane_dirty()


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

	var top_mat   = palette_ref.get_material_for_surface(material_index, 0)
	var sides_mat = palette_ref.get_material_for_surface(material_index, 1)
	var bot_mat   = palette_ref.get_material_for_surface(material_index, 2)

	# Apply to the 3D tile mesh — all surfaces identified by role name
	if pos in tile_meshes:
		apply_palette_materials_to_mesh(tile_meshes[pos], [top_mat, sides_mat, bot_mat])

	# Update the top-plane overlay — always a single-surface mesh, surface 0
	if pos in _top_plane_nodes:
		_top_plane_nodes[pos].set_surface_override_material(0, top_mat)
	elif not tile_manager.batch_mode:
		_top_plane_dirty_positions[pos] = true
		_flush_top_plane_dirty()


func get_tile_material_index(pos: Vector3i) -> int:
	"""Get the material index for a tile at the given position"""
	return tile_materials.get(pos, -1)


func remove_tile(pos: Vector3i):
	# Guard: if the tile is already gone there is nothing to do.  Without this
	# check the dirty-marking and flush below run on every repeated call even
	# though tile_manager.remove_tile() already returned early, causing the
	# identical-flush loop visible in the debug log.
	if pos not in tiles:
		return
	tile_manager.remove_tile(pos)
	# Stash the material index so that a subsequent place_tile at the same
	# position (e.g. the editor's erase-then-repaint pattern) can restore it.
	# We keep the entry in tile_materials rather than erasing it; the tile is
	# gone from `tiles` so the stashed value is inert until the tile is re-placed.
	# Do NOT erase tile_materials[pos] here.
	_mark_top_plane_dirty_around(pos)
	var below = pos + Vector3i(0, -1, 0)
	if below in tiles:
		_mark_top_plane_dirty_around(below)

	for diag in [Vector3i(1,0,1), Vector3i(1,0,-1), Vector3i(-1,0,1), Vector3i(-1,0,-1)]:
		var diag_pos = pos + diag
		if diag_pos in tiles:
			_top_plane_dirty_positions[diag_pos] = true

	if below in tiles:
		for cardinal in [Vector3i(1,0,0), Vector3i(-1,0,0), Vector3i(0,0,1), Vector3i(0,0,-1)]:
			var below_neighbor = below + cardinal
			if below_neighbor in tiles:
				_top_plane_dirty_positions[below_neighbor] = true

	_flush_top_plane_dirty()


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
# IN-EDITOR MESH GENERATION (Delegate to MeshOptimizer)
# ============================================================================

func generate_optimized_level_mesh() -> ArrayMesh:
	return mesh_optimizer.generate_optimized_level_mesh()


func generate_optimized_level_mesh_multi_material() -> ArrayMesh:
	return mesh_optimizer.generate_optimized_level_mesh_multi_material()


# ============================================================================
# EXPORT (Delegate to GlbExporter)
# ============================================================================

func capture_top_plane_snapshot() -> Array:
	"""Capture top-plane quad data from the live scene nodes into a plain Array.
	Must be called on the main thread. Pass the result to the export worker thread
	so it never touches scene nodes directly."""
	var snapshot: Array = []
	for pos in _top_plane_nodes:
		var mi: MeshInstance3D = _top_plane_nodes[pos]
		if mi and is_instance_valid(mi):
			snapshot.append({
				"grid_pos": pos,
				"position": mi.position,
				"scale":    mi.scale,
				"material": mi.get_surface_override_material(0),
			})
	return snapshot


func build_export_mesh(top_plane_snapshot: Array = []) -> ArrayMesh:
	"""Build a single combined export mesh. Worker-thread safe.
	top_plane_snapshot must be captured on the main thread first."""
	var snap := top_plane_snapshot if not top_plane_snapshot.is_empty() \
			else capture_top_plane_snapshot()
	return glb_exporter.build_export_mesh(snap)


func build_chunk_meshes(save_name: String, top_plane_snapshot: Array = [],
		chunk_size: Vector3i = GlbExporter.CHUNK_SIZE) -> Dictionary:
	"""Build all chunk meshes. Worker-thread safe.
	top_plane_snapshot must be captured on the main thread first."""
	var snap := top_plane_snapshot if not top_plane_snapshot.is_empty() \
			else capture_top_plane_snapshot()
	return glb_exporter.build_chunk_meshes(save_name, snap, chunk_size)


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
