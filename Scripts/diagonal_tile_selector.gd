class_name DiagonalTileSelector extends RefCounted

# Tile type constants - you'll need to define these based on your meshes
const TILE_FULL_BLOCK = 3
const TILE_INNER_CORNER = 4  # Your half_bevel.obj

# Corner configuration enum
enum CornerType {
	NONE,           # No special corner
	INNER_CORNER,   # Missing diagonal (your Case 1)
	OUTER_CORNER,   # Has diagonal
	EDGE,           # Single neighbor
	CORRIDOR        # Opposite neighbors
}

# Neighbor direction enum (matches your existing system)
enum NeighborDir {
	NORTH,
	SOUTH,
	EAST,
	WEST,
	UP,
	DOWN,
	NORTH_EAST,
	NORTH_WEST,
	SOUTH_EAST,
	SOUTH_WEST
}

# Result structure
class TileConfig:
	var tile_type: int
	var rotation: float
	var corner_type: CornerType
	
	func _init(type: int, rot: float, corner: CornerType):
		tile_type = type
		rotation = rot
		corner_type = corner

# Detect what type of tile configuration this position needs
func get_tile_configuration(pos: Vector3i, tiles: Dictionary) -> TileConfig:
	var neighbors = _get_all_neighbors(pos, tiles)
	
	# Count cardinal neighbors
	var cardinal_count = 0
	cardinal_count += 1 if neighbors[NeighborDir.NORTH] else 0
	cardinal_count += 1 if neighbors[NeighborDir.SOUTH] else 0
	cardinal_count += 1 if neighbors[NeighborDir.EAST] else 0
	cardinal_count += 1 if neighbors[NeighborDir.WEST] else 0
	
	# If surrounded or isolated, just use full block
	if cardinal_count == 0 or cardinal_count == 4:
		return TileConfig.new(TILE_FULL_BLOCK, 0.0, CornerType.NONE)
	
	# Single neighbor - could be edge tile
	if cardinal_count == 1:
		return _handle_single_neighbor(neighbors)
	
	# Two neighbors - check if corner or corridor
	if cardinal_count == 2:
		return _handle_two_neighbors(neighbors)
	
	# Three neighbors - check which side is open
	if cardinal_count == 3:
		return _handle_three_neighbors(neighbors)
	
	return TileConfig.new(TILE_FULL_BLOCK, 0.0, CornerType.NONE)

# Handle single neighbor configuration
func _handle_single_neighbor(neighbors: Dictionary) -> TileConfig:
	var has_north = neighbors[NeighborDir.NORTH]
	var has_south = neighbors[NeighborDir.SOUTH]
	var has_east = neighbors[NeighborDir.EAST]
	var has_west = neighbors[NeighborDir.WEST]
	
	# Block has one neighbor - needs bevel on the corner TOUCHING that neighbor
	var rotation = 0.0
	
	if has_north:
		# Neighbor to north - cut SE corner (where they would meet diagonally)
		rotation = 270.0
	elif has_south:
		# Neighbor to south - cut NE corner
		rotation = 180.0
	elif has_east:
		# Neighbor to east - cut SW corner
		rotation = 90.0
	elif has_west:
		# Neighbor to west - cut NW corner
		rotation = 0.0
	
	return TileConfig.new(TILE_INNER_CORNER, rotation, CornerType.EDGE)

# Handle two neighbor configuration (THIS IS THE KEY ONE!)
func _handle_two_neighbors(neighbors: Dictionary) -> TileConfig:
	var has_north = neighbors[NeighborDir.NORTH]
	var has_south = neighbors[NeighborDir.SOUTH]
	var has_east = neighbors[NeighborDir.EAST]
	var has_west = neighbors[NeighborDir.WEST]
	
	# Check if it's a corridor (opposite sides) - keep as full block
	if (has_north and has_south) or (has_east and has_west):
		return TileConfig.new(TILE_FULL_BLOCK, 0.0, CornerType.CORRIDOR)
	
	# Adjacent corners - block is in the MIDDLE of an L-shape
	# These should STAY as full blocks - they're the junction point
	var diagonal_exists = false
	
	if has_north and has_east:
		diagonal_exists = neighbors[NeighborDir.NORTH_EAST]
	elif has_east and has_south:
		diagonal_exists = neighbors[NeighborDir.SOUTH_EAST]
	elif has_south and has_west:
		diagonal_exists = neighbors[NeighborDir.SOUTH_WEST]
	elif has_west and has_north:
		diagonal_exists = neighbors[NeighborDir.NORTH_WEST]
	
	# Block with 2 adjacent neighbors is a junction - always full block
	return TileConfig.new(TILE_FULL_BLOCK, 0.0, CornerType.INNER_CORNER if not diagonal_exists else CornerType.OUTER_CORNER)

# Handle three neighbor configuration
func _handle_three_neighbors(_neighbors: Dictionary) -> TileConfig:
	# For now, use full block
	# You could add T-junction tiles later
	return TileConfig.new(TILE_FULL_BLOCK, 0.0, CornerType.NONE)

# Get all 8 horizontal neighbors (4 cardinal + 4 diagonal)
func _get_all_neighbors(pos: Vector3i, tiles: Dictionary) -> Dictionary:
	var result = {}
	result[NeighborDir.NORTH] = (pos + Vector3i(0, 0, -1)) in tiles
	result[NeighborDir.SOUTH] = (pos + Vector3i(0, 0, 1)) in tiles
	result[NeighborDir.EAST] = (pos + Vector3i(1, 0, 0)) in tiles
	result[NeighborDir.WEST] = (pos + Vector3i(-1, 0, 0)) in tiles
	result[NeighborDir.NORTH_EAST] = (pos + Vector3i(1, 0, -1)) in tiles
	result[NeighborDir.NORTH_WEST] = (pos + Vector3i(-1, 0, -1)) in tiles
	result[NeighborDir.SOUTH_EAST] = (pos + Vector3i(1, 0, 1)) in tiles
	result[NeighborDir.SOUTH_WEST] = (pos + Vector3i(-1, 0, 1)) in tiles
	result[NeighborDir.UP] = (pos + Vector3i(0, 1, 0)) in tiles
	result[NeighborDir.DOWN] = (pos + Vector3i(0, -1, 0)) in tiles
	return result
