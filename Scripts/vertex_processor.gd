class_name VertexProcessor extends RefCounted

var tile_map: TileMap3D
var tiles: Dictionary
var grid_size: float

func setup(tilemap: TileMap3D, tiles_ref: Dictionary, grid_sz: float):
	tile_map = tilemap
	tiles = tiles_ref
	grid_size = grid_sz

# Extended version with rotation-aware extension
func extend_to_boundary_if_neighbor_rotated(vertex: Vector3, neighbors: Dictionary, 
											threshold: float, _pos: Vector3i, 
											rotation_degrees: float) -> Vector3:
	var extended = vertex
	var s = grid_size
	var half = s * 0.5
	var overlap = 0.0

	# The custom bulge mesh is authored in centered space [-s/2, +s/2].
	# Detect which space we're in by checking if any coordinate is negative.
	# [0, s] meshes (simple tiles) never have negative X/Z; centered meshes do.
	var is_centered = vertex.x < -0.01 or vertex.z < -0.01

	# Boundary targets depend on coordinate space
	var x_min_bound: float = -half - overlap if is_centered else -overlap
	var x_max_bound: float =  half + overlap if is_centered else s + overlap
	var z_min_bound: float = -half - overlap if is_centered else -overlap
	var z_max_bound: float =  half + overlap if is_centered else s + overlap

	# Near-edge thresholds also depend on space
	var x_min_thresh: float = (-half + threshold) if is_centered else threshold
	var x_max_thresh: float = ( half - threshold) if is_centered else (s - threshold)
	var z_min_thresh: float = (-half + threshold) if is_centered else threshold
	var z_max_thresh: float = ( half - threshold) if is_centered else (s - threshold)

	# Get neighbor info
	var has_west  = neighbors[MeshGenerator.NeighborDir.WEST]  != -1
	var has_east  = neighbors[MeshGenerator.NeighborDir.EAST]  != -1
	var has_north = neighbors[MeshGenerator.NeighborDir.NORTH] != -1
	var has_south = neighbors[MeshGenerator.NeighborDir.SOUTH] != -1
	var has_up    = neighbors[MeshGenerator.NeighborDir.UP]    != -1
	var has_down  = neighbors[MeshGenerator.NeighborDir.DOWN]  != -1

	# Check if vertex is near edges
	var near_x_min = vertex.x < x_min_thresh
	var near_x_max = vertex.x > x_max_thresh
	var near_z_min = vertex.z < z_min_thresh
	var near_z_max = vertex.z > z_max_thresh
	var near_y_min = vertex.y < threshold
	var near_y_max = vertex.y > s - threshold

	# VERTICAL EXTENSION
	if near_y_min and has_down:
		extended.y = -overlap
	if near_y_max and has_up:
		extended.y = s + overlap

	# Check if this tile is rotated at a diagonal angle (not 0, 90, 180, 270)
	var rot = fmod(abs(rotation_degrees) + 360.0, 360.0)
	var is_diagonal_rotation = abs(fmod(rot, 90.0)) > 1.0

	if is_diagonal_rotation:
		# For diagonally rotated tiles, extend corners aggressively to fill gaps
		var corner_reach = s * 0.15  # Reach into neighboring cells

		# Extend corners outward when there are cardinal neighbors
		# The rotated tile's corners fill the space between cardinal neighbors
		if near_x_min and near_z_min:
			if has_west or has_north:
				extended.x = min(extended.x, x_min_bound - corner_reach)
				extended.z = min(extended.z, z_min_bound - corner_reach)

		if near_x_max and near_z_min:
			if has_east or has_north:
				extended.x = max(extended.x, x_max_bound + corner_reach)
				extended.z = min(extended.z, z_min_bound - corner_reach)

		if near_x_min and near_z_max:
			if has_west or has_south:
				extended.x = min(extended.x, x_min_bound - corner_reach)
				extended.z = max(extended.z, z_max_bound + corner_reach)

		if near_x_max and near_z_max:
			if has_east or has_south:
				extended.x = max(extended.x, x_max_bound + corner_reach)
				extended.z = max(extended.z, z_max_bound + corner_reach)
	else:
		# For non-rotated or 90° rotated tiles, extend to boundaries
		if near_x_min and has_west:
			extended.x = x_min_bound
		if near_x_max and has_east:
			extended.x = x_max_bound
		if near_z_min and has_north:
			extended.z = z_min_bound
		if near_z_max and has_south:
			extended.z = z_max_bound

		# Corner extension for non-rotated tiles
		# When both perpendicular neighbors exist, extend corner vertices
		if near_x_min and near_z_min and has_west and has_north:
			extended.x = x_min_bound
			extended.z = z_min_bound

		if near_x_max and near_z_min and has_east and has_north:
			extended.x = x_max_bound
			extended.z = z_min_bound

		if near_x_min and near_z_max and has_west and has_south:
			extended.x = x_min_bound
			extended.z = z_max_bound

		if near_x_max and near_z_max and has_east and has_south:
			extended.x = x_max_bound
			extended.z = z_max_bound

	return extended


func extend_to_boundary_if_neighbor(vertex: Vector3, neighbors: Dictionary, threshold: float) -> Vector3:
	var extended = vertex
	var s = grid_size
	var overlap = 0.0
	
	# VERTICAL EXTENSION
	if vertex.y < threshold:
		if neighbors[MeshGenerator.NeighborDir.DOWN] != -1:
			extended.y = -overlap
	
	if vertex.y > s - threshold:
		if neighbors[MeshGenerator.NeighborDir.UP] != -1:
			extended.y = s + overlap
	
	# HORIZONTAL EXTENSION
	if vertex.x < threshold:
		if neighbors[MeshGenerator.NeighborDir.WEST] != -1:
			extended.x = -overlap
	
	if vertex.x > s - threshold:
		if neighbors[MeshGenerator.NeighborDir.EAST] != -1:
			extended.x = s + overlap
	
	if vertex.z < threshold:
		if neighbors[MeshGenerator.NeighborDir.NORTH] != -1:
			extended.z = -overlap
	
	if vertex.z > s - threshold:
		if neighbors[MeshGenerator.NeighborDir.SOUTH] != -1:
			extended.z = s + overlap
	
	return extended
