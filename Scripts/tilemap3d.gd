class_name TileMap3D extends RefCounted


# Slant direction enum
enum SlantType {
	NONE = 0,
	NW_SE = 1,  # Northwest to Southeast diagonal
	NE_SW = 2   # Northeast to Southwest diagonal
}

# ============================================================================
# CORE DATA
# ============================================================================
var tiles = {}  # Vector3i -> tile_type
var tile_slants = {}  # Vector3i -> SlantType (ADD THIS LINE)
var tile_meshes = {}  # Vector3i -> MeshInstance3D
var custom_meshes = {}  # tile_type -> ArrayMesh (custom loaded meshes)
var custom_materials: Dictionary = {}  # tile_type -> Array[Material]
var grid_size: float = 1.0
var parent_node: Node3D
var offset_provider: Callable

# ============================================================================
# COMPONENTS
# ============================================================================
var mesh_loader: MeshLoader
var mesh_generator: MeshGenerator
var mesh_editor: MeshEditor
var material_manager: MaterialManager
var tile_manager: TileManager
var mesh_optimizer: MeshOptimizer

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


func set_offset_provider(provider: Callable):
	offset_provider = provider


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


func remove_tile(pos: Vector3i):
	tile_manager.remove_tile(pos)


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

func generate_custom_tile_mesh(pos: Vector3i, tile_type: int, neighbors: Dictionary) -> ArrayMesh:
	return mesh_generator.generate_custom_tile_mesh(pos, tile_type, neighbors)


func generate_tile_mesh(pos: Vector3i, tile_type: int, neighbors: Dictionary) -> ArrayMesh:
	return mesh_generator.generate_tile_mesh(pos, tile_type, neighbors)


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


# ============================================================================
# SLANT MANAGEMENT
# ============================================================================

func toggle_tile_slant(pos: Vector3i):
	if not has_tile(pos):
		return
	
	var current_slant = tile_slants.get(pos, SlantType.NONE)
	
	# Simple toggle: NONE -> Auto-detected -> NONE
	if current_slant == SlantType.NONE:
		tile_slants[pos] = _auto_determine_slant(pos)
	else:
		tile_slants.erase(pos)  # Remove slant (back to NONE)
	
	update_tile_mesh(pos)
	print("Tile at ", pos, " slant: ", tile_slants.get(pos, SlantType.NONE))


func get_tile_slant(pos: Vector3i) -> int:
	return tile_slants.get(pos, SlantType.NONE)


func _auto_determine_slant(pos: Vector3i) -> int:
	# Get all 8 neighbors on the SAME Y-level
	var n = has_tile(pos + Vector3i(0, 0, -1))   # North
	var s = has_tile(pos + Vector3i(0, 0, 1))    # South
	var e = has_tile(pos + Vector3i(1, 0, 0))    # East
	var w = has_tile(pos + Vector3i(-1, 0, 0))   # West
	var nw = has_tile(pos + Vector3i(-1, 0, -1)) # Northwest
	var ne = has_tile(pos + Vector3i(1, 0, -1))  # Northeast
	var sw = has_tile(pos + Vector3i(-1, 0, 1))  # Southwest
	var se = has_tile(pos + Vector3i(1, 0, 1))   # Southeast
	
	# Count orthogonal vs diagonal neighbors
	var orthogonal_count = (1 if n else 0) + (1 if s else 0) + (1 if e else 0) + (1 if w else 0)
	var diagonal_count = (1 if nw else 0) + (1 if ne else 0) + (1 if sw else 0) + (1 if se else 0)
	
	# Pattern detection: Look for diagonal corridors
	
	# NW-SE Pattern: Has neighbors on NW-SE diagonal but missing on NE-SW
	# Examples: corridor from northwest to southeast
	if (nw or se) and not (ne or sw):
		# Strong diagonal pattern on NW-SE axis
		return SlantType.NW_SE
	
	# NE-SW Pattern: Has neighbors on NE-SW diagonal but missing on NW-SE
	if (ne or sw) and not (nw or se):
		# Strong diagonal pattern on NE-SW axis
		return SlantType.NE_SW
	
	# Check for corner patterns (tile is at a corner/turn)
	# NW corner: has north and west, but not south or east
	if n and w and not (s or e):
		if nw:  # Has diagonal neighbor too
			return SlantType.NW_SE
	
	# NE corner: has north and east, but not south or west
	if n and e and not (s or w):
		if ne:
			return SlantType.NE_SW
	
	# SW corner: has south and west, but not north or east
	if s and w and not (n or e):
		if sw:
			return SlantType.NE_SW
	
	# SE corner: has south and east, but not north or west
	if s and e and not (n or w):
		if se:
			return SlantType.NW_SE
	
	# Check if any diagonal neighbors already have slants - match them
	var nw_slant = get_tile_slant(pos + Vector3i(-1, 0, -1))
	var ne_slant = get_tile_slant(pos + Vector3i(1, 0, -1))
	var sw_slant = get_tile_slant(pos + Vector3i(-1, 0, 1))
	var se_slant = get_tile_slant(pos + Vector3i(1, 0, 1))
	
	# Match adjacent slant directions
	if (nw_slant == SlantType.NW_SE or se_slant == SlantType.NW_SE):
		return SlantType.NW_SE
	if (ne_slant == SlantType.NE_SW or sw_slant == SlantType.NE_SW):
		return SlantType.NE_SW
	
	# If more diagonal neighbors than orthogonal, pick based on which diagonal
	if diagonal_count > orthogonal_count:
		var nw_se_score = (1 if nw else 0) + (1 if se else 0)
		var ne_sw_score = (1 if ne else 0) + (1 if sw else 0)
		
		if nw_se_score > ne_sw_score:
			return SlantType.NW_SE
		elif ne_sw_score > nw_se_score:
			return SlantType.NE_SW
	
	# Edge detection: Tile is on an edge facing empty space
	# If surrounded mostly by empty space on one diagonal axis, use that axis
	var nw_empty = not nw
	var ne_empty = not ne
	var sw_empty = not sw
	var se_empty = not se
	
	# If NW and SE are empty (edge along NE-SW)
	if nw_empty and se_empty and (ne or sw):
		return SlantType.NE_SW
	
	# If NE and SW are empty (edge along NW-SE)
	if ne_empty and sw_empty and (nw or se):
		return SlantType.NW_SE
	
	# Default fallback: use orthogonal count as before
	var ns_count = (1 if n else 0) + (1 if s else 0)
	var ew_count = (1 if e else 0) + (1 if w else 0)
	
	if ns_count > ew_count:
		return SlantType.NE_SW  # Align perpendicular to N-S axis
	else:
		return SlantType.NW_SE  # Align perpendicular to E-W axis
