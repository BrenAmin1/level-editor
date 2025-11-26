class_name CullingManager extends RefCounted

var tile_map: TileMap3D
var tiles: Dictionary
var grid_size: float
var batch_mode_skip_culling: bool = false

enum DiagonalDirections {
		NW,
		NE,
		SW,
		SE
	}

func setup(tilemap: TileMap3D, tiles_ref: Dictionary, grid_sz: float):
	tile_map = tilemap
	tiles = tiles_ref
	grid_size = grid_sz

func find_exposed_corners(pos: Vector3i, neighbors: Dictionary) -> Array:
	var exposed_corners = []
	var NeighborDir = MeshGenerator.NeighborDir

	if neighbors[NeighborDir.NORTH] != -1 and neighbors[NeighborDir.WEST] != -1:
		if (pos + Vector3i(-1, 0, -1)) not in tiles:
			exposed_corners.append(DiagonalDirections.NW)
	if neighbors[NeighborDir.NORTH] != -1 and neighbors[NeighborDir.EAST] != -1:
		if (pos + Vector3i(1, 0, -1)) not in tiles:
			exposed_corners.append(DiagonalDirections.NE)
	if neighbors[NeighborDir.SOUTH] != -1 and neighbors[NeighborDir.WEST] != -1:
		if (pos + Vector3i(-1, 0, 1)) not in tiles:
			exposed_corners.append(DiagonalDirections.SW)
	if neighbors[NeighborDir.SOUTH] != -1 and neighbors[NeighborDir.EAST] != -1:
		if (pos + Vector3i(1, 0, 1)) not in tiles:
			exposed_corners.append(DiagonalDirections.SE)
	
	return exposed_corners

func should_cull_triangle(pos: Vector3i, neighbors: Dictionary, face_center: Vector3, 
						  face_normal: Vector3, exposed_corners: Array, disable_all_culling: bool) -> bool:
	if batch_mode_skip_culling:
		return false
	var NeighborDir = MeshGenerator.NeighborDir
	var interior_margin = 0.15
	var s = grid_size
	
	# Determine if we're in top half or bottom half
	var is_top_half = face_center.y >= s * 0.5
	
	# West side
	if neighbors[NeighborDir.WEST] != -1 and not _should_render_vertical_face(pos, pos + Vector3i(-1, 0, 0)):
		if face_center.x < interior_margin:
			var is_near_corner = (DiagonalDirections.NW in exposed_corners and face_center.z < s * 0.5) or \
								 (DiagonalDirections.SW in exposed_corners and face_center.z > s * 0.5)
			if not is_near_corner and face_normal.x < -0.7:
				# Don't cull top half if there's a block above (needs to be visible)
				if is_top_half and disable_all_culling:
					return false
				return true
	
	# East side
	if neighbors[NeighborDir.EAST] != -1 and not _should_render_vertical_face(pos, pos + Vector3i(1, 0, 0)):
		if face_center.x > s - interior_margin:
			var is_near_corner = (DiagonalDirections.NE in exposed_corners and face_center.z < s * 0.5) or \
								 (DiagonalDirections.SE in exposed_corners and face_center.z > s * 0.5)
			if not is_near_corner and face_normal.x > 0.7:
				if is_top_half and disable_all_culling:
					return false
				return true
	
	# Bottom face - cull if neighbor below
	if neighbors[NeighborDir.DOWN] != -1 and not _should_render_vertical_face(pos, pos + Vector3i(0, -1, 0)):
		if face_center.y < interior_margin and face_normal.y < -0.7:
			return true
	
	# Top face - cull if block above
	if neighbors[NeighborDir.UP] != -1 and not _should_render_vertical_face(pos, pos + Vector3i(0, 1, 0)):
		if face_center.y > s - interior_margin and face_normal.y > 0.7:
			return true
	
	# North side
	if neighbors[NeighborDir.NORTH] != -1 and not _should_render_vertical_face(pos, pos + Vector3i(0, 0, -1)):
		if face_center.z < interior_margin:
			var is_near_corner = (DiagonalDirections.NW in exposed_corners and face_center.x < s * 0.5) or \
								 (DiagonalDirections.NE in exposed_corners and face_center.x > s * 0.5)
			if not is_near_corner and face_normal.z < -0.7:
				if is_top_half and disable_all_culling:
					return false
				return true
	
	# South side
	if neighbors[NeighborDir.SOUTH] != -1 and not _should_render_vertical_face(pos, pos + Vector3i(0, 0, 1)):
		if face_center.z > s - interior_margin:
			var is_near_corner = (DiagonalDirections.SW in exposed_corners and face_center.x < s * 0.5) or \
								 (DiagonalDirections.SE in exposed_corners and face_center.x > s * 0.5)
			if not is_near_corner and face_normal.z > 0.7:
				if is_top_half and disable_all_culling:
					return false
				return true
	
	return false

func _should_render_vertical_face(current_pos: Vector3i, neighbor_pos: Vector3i) -> bool:
	if neighbor_pos not in tiles:
		return true
	var current_offset = tile_map.get_offset_for_y(current_pos.y)
	var neighbor_offset = tile_map.get_offset_for_y(neighbor_pos.y)
	return not current_offset.is_equal_approx(neighbor_offset)
