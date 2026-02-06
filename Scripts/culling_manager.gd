class_name CullingManager extends RefCounted

var tile_map: TileMap3D
var tiles: Dictionary
var grid_size: float
var batch_mode_skip_culling: bool = false

func setup(tilemap: TileMap3D, tiles_ref: Dictionary, grid_sz: float):
	tile_map = tilemap
	tiles = tiles_ref
	grid_size = grid_sz

func find_exposed_corners(neighbors: Dictionary) -> Array:
	var exposed_corners = []
	var NeighborDir = MeshGenerator.NeighborDir
	#print("Finding corners - DIAG_NW: ", neighbors.get(NeighborDir.DIAGONAL_NW, -1))
	# Use the neighbor data passed in, not live tile lookups
	if neighbors[NeighborDir.NORTH] != -1 and neighbors[NeighborDir.WEST] != -1:
		if neighbors.get(NeighborDir.DIAGONAL_NW, -1) == -1:
			exposed_corners.append(NeighborDir.DIAGONAL_NW)
	
	if neighbors[NeighborDir.NORTH] != -1 and neighbors[NeighborDir.EAST] != -1:
		if neighbors.get(NeighborDir.DIAGONAL_NE, -1) == -1:
			exposed_corners.append(NeighborDir.DIAGONAL_NE)
	
	if neighbors[NeighborDir.SOUTH] != -1 and neighbors[NeighborDir.WEST] != -1:
		if neighbors.get(NeighborDir.DIAGONAL_SW, -1) == -1:
			exposed_corners.append(NeighborDir.DIAGONAL_SW)
	
	if neighbors[NeighborDir.SOUTH] != -1 and neighbors[NeighborDir.EAST] != -1:
		if neighbors.get(NeighborDir.DIAGONAL_SE, -1) == -1:
			exposed_corners.append(NeighborDir.DIAGONAL_SE)
	
	return exposed_corners

func should_cull_triangle(pos: Vector3i, neighbors: Dictionary, face_center: Vector3, 
						  face_normal: Vector3, exposed_corners: Array, disable_all_culling: bool) -> bool:
	if batch_mode_skip_culling:
		return false
	
	var NeighborDir = MeshGenerator.NeighborDir
	
	# Cull based on face normal direction, NOT position
	# If face points toward a neighbor at same Y level, cull it
	
	# West face (normal pointing in -X direction)
	if face_normal.x < -0.7:
		if neighbors[NeighborDir.WEST] != -1:
			var neighbor_pos = pos + Vector3i(-1, 0, 0)
			if neighbor_pos.y == pos.y or not _should_render_vertical_face(pos, neighbor_pos):
				return true
	
	# East face (normal pointing in +X direction)
	if face_normal.x > 0.7:
		if neighbors[NeighborDir.EAST] != -1:
			var neighbor_pos = pos + Vector3i(1, 0, 0)
			if neighbor_pos.y == pos.y or not _should_render_vertical_face(pos, neighbor_pos):
				return true
	
	# North face (normal pointing in -Z direction)
	if face_normal.z < -0.7:
		if neighbors[NeighborDir.NORTH] != -1:
			var neighbor_pos = pos + Vector3i(0, 0, -1)
			if neighbor_pos.y == pos.y or not _should_render_vertical_face(pos, neighbor_pos):
				return true
	
	# South face (normal pointing in +Z direction)
	if face_normal.z > 0.7:
		if neighbors[NeighborDir.SOUTH] != -1:
			var neighbor_pos = pos + Vector3i(0, 0, 1)
			if neighbor_pos.y == pos.y or not _should_render_vertical_face(pos, neighbor_pos):
				return true
	
	# Bottom face (normal pointing in -Y direction)
	if face_normal.y < -0.7:
		if neighbors[NeighborDir.DOWN] != -1:
			return true
	
	# Top face (normal pointing in +Y direction)
	if face_normal.y > 0.7:
		if neighbors[NeighborDir.UP] != -1:
			var neighbor_pos = pos + Vector3i(0, 1, 0)
			if neighbor_pos.y == pos.y or not _should_render_vertical_face(pos, neighbor_pos):
				return true
	
	return false

func _should_render_vertical_face(current_pos: Vector3i, neighbor_pos: Vector3i) -> bool:
	if neighbor_pos not in tiles:
		return true
	var current_offset = tile_map.get_offset_for_y(current_pos.y)
	var neighbor_offset = tile_map.get_offset_for_y(neighbor_pos.y)
	return not current_offset.is_equal_approx(neighbor_offset)
