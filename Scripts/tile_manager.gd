class_name TileManager extends RefCounted

# References to parent TileMap3D data and components
var tiles: Dictionary  # Reference to TileMap3D.tiles
var tile_meshes: Dictionary  # Reference to TileMap3D.tile_meshes
var custom_meshes: Dictionary  # Reference to TileMap3D.custom_meshes
var grid_size: float  # Reference to TileMap3D.grid_size
var parent_node: Node3D  # Reference to TileMap3D.parent_node
var tile_map: TileMap3D  # Reference to parent for calling methods
var mesh_generator: MeshGenerator  # Reference to MeshGenerator component

# ============================================================================
# SETUP
# ============================================================================

func setup(tilemap: TileMap3D, tiles_ref: Dictionary, tile_meshes_ref: Dictionary, 
		   meshes_ref: Dictionary, grid_sz: float, parent: Node3D, generator: MeshGenerator):
	tile_map = tilemap
	tiles = tiles_ref
	tile_meshes = tile_meshes_ref
	custom_meshes = meshes_ref
	grid_size = grid_sz
	parent_node = parent
	mesh_generator = generator

# ============================================================================
# COORDINATE CONVERSION
# ============================================================================

func world_to_grid(pos: Vector3) -> Vector3i:
	return Vector3i(
		floori(pos.x / grid_size),
		floori(pos.y / grid_size),
		floori(pos.z / grid_size)
	)


func grid_to_world(pos: Vector3i) -> Vector3:
	var offset = tile_map.get_offset_for_y(pos.y)
	return Vector3(pos.x * grid_size + offset.x, pos.y * grid_size, pos.z * grid_size + offset.y)

# ============================================================================
# TILE MANIPULATION
# ============================================================================

func place_tile(pos: Vector3i, tile_type: int):
	tiles[pos] = tile_type
	
	update_tile_mesh(pos)
	
	# Update direct neighbors (6 directions)
	for offset in [
		Vector3i(1,0,0), Vector3i(-1,0,0),
		Vector3i(0,1,0), Vector3i(0,-1,0),
		Vector3i(0,0,1), Vector3i(0,0,-1)
	]:
		var neighbor_pos = pos + offset
		if neighbor_pos in tiles:
			update_tile_mesh(neighbor_pos)
	
	# Update diagonal neighbors (4 corners) - they may have exposed corners now
	for offset in [
		Vector3i(1, 0, 1),   # Southeast
		Vector3i(1, 0, -1),  # Northeast
		Vector3i(-1, 0, 1),  # Southwest
		Vector3i(-1, 0, -1)  # Northwest
	]:
		var neighbor_pos = pos + offset
		if neighbor_pos in tiles:
			update_tile_mesh(neighbor_pos)


func remove_tile(pos: Vector3i):
	if pos not in tiles:
		return
	
	tiles.erase(pos)
	
	if pos in tile_meshes:
		tile_meshes[pos].queue_free()
		tile_meshes.erase(pos)
	
	# Update direct neighbors (6 directions)
	for offset in [
		Vector3i(1,0,0), Vector3i(-1,0,0),
		Vector3i(0,1,0), Vector3i(0,-1,0),
		Vector3i(0,0,1), Vector3i(0,0,-1)
	]:
		var neighbor_pos = pos + offset
		if neighbor_pos in tiles:
			update_tile_mesh(neighbor_pos)
	
	# Update diagonal neighbors (4 corners) - they may have exposed corners now
	for offset in [
		Vector3i(1, 0, 1),   # Southeast
		Vector3i(1, 0, -1),  # Northeast
		Vector3i(-1, 0, 1),  # Southwest
		Vector3i(-1, 0, -1)  # Northwest
	]:
		var neighbor_pos = pos + offset
		if neighbor_pos in tiles:
			update_tile_mesh(neighbor_pos)

func has_tile(pos: Vector3i) -> bool:
	return pos in tiles

func get_tile_type(pos: Vector3i) -> int:
	return tiles.get(pos, -1)

# ============================================================================
# MESH MANAGEMENT
# ============================================================================

func update_tile_mesh(pos: Vector3i):
	if not parent_node:
		return
	
	var tile_type = tiles[pos]
	
	# Use custom mesh if available, otherwise generate default
	var mesh: ArrayMesh
	if tile_type in custom_meshes:
		var neighbors = get_neighbors(pos)
		mesh = mesh_generator.generate_custom_tile_mesh(pos, tile_type, neighbors)
	else:
		var neighbors = get_neighbors(pos)
		mesh = mesh_generator.generate_tile_mesh(tile_type, neighbors)
	
	if pos in tile_meshes:
		tile_meshes[pos].mesh = mesh
		tile_meshes[pos].position = grid_to_world(pos)
	else:
		var mesh_instance = MeshInstance3D.new()
		mesh_instance.mesh = mesh
		mesh_instance.position = grid_to_world(pos)
		mesh_instance.process_priority = 1
		
		var static_body = StaticBody3D.new()
		var collision_shape = CollisionShape3D.new()
		var box_shape = BoxShape3D.new()
		box_shape.size = Vector3(grid_size, grid_size, grid_size)
		collision_shape.shape = box_shape
		collision_shape.position = Vector3(grid_size/2, grid_size/2, grid_size/2)
		static_body.add_child(collision_shape)
		mesh_instance.add_child(static_body)
		
		parent_node.add_child(mesh_instance)
		tile_meshes[pos] = mesh_instance

# ============================================================================
# NEIGHBOR QUERIES
# ============================================================================

func get_neighbors(pos: Vector3i) -> Dictionary:
	var neighbors : Dictionary = {}
	neighbors[MeshGenerator.NeighborDir.NORTH] = tiles.get(pos + Vector3i(0, 0, -1), -1)
	neighbors[MeshGenerator.NeighborDir.SOUTH] = tiles.get(pos + Vector3i(0, 0, 1), -1)
	neighbors[MeshGenerator.NeighborDir.EAST] = tiles.get(pos + Vector3i(1, 0, 0), -1)
	neighbors[MeshGenerator.NeighborDir.WEST] = tiles.get(pos + Vector3i(-1, 0, 0), -1)
	neighbors[MeshGenerator.NeighborDir.UP] = tiles.get(pos + Vector3i(0, 1, 0), -1)
	neighbors[MeshGenerator.NeighborDir.DOWN] = tiles.get(pos + Vector3i(0, -1, 0), -1)
	return neighbors
