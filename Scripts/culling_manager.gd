class_name CullingManager extends RefCounted

var tile_map: TileMap3D
var tiles: Dictionary
var grid_size: float

func setup(tilemap: TileMap3D, tiles_ref: Dictionary, grid_sz: float):
	tile_map = tilemap
	tiles = tiles_ref
	grid_size = grid_sz

func find_exposed_corners(pos: Vector3i, neighbors: Dictionary) -> Array:
	var exposed_corners = []
	var NeighborDir = MeshGenerator.NeighborDir
	
	if neighbors[NeighborDir.NORTH] != -1 and neighbors[NeighborDir.WEST] != -1:
		if (pos + Vector3i(-1, 0, -1)) not in tiles:
			exposed_corners.append("NW")
	if neighbors[NeighborDir.NORTH] != -1 and neighbors[NeighborDir.EAST] != -1:
		if (pos + Vector3i(1, 0, -1)) not in tiles:
			exposed_corners.append("NE")
	if neighbors[NeighborDir.SOUTH] != -1 and neighbors[NeighborDir.WEST] != -1:
		if (pos + Vector3i(-1, 0, 1)) not in tiles:
			exposed_corners.append("SW")
	if neighbors[NeighborDir.SOUTH] != -1 and neighbors[NeighborDir.EAST] != -1:
		if (pos + Vector3i(1, 0, 1)) not in tiles:
			exposed_corners.append("SE")
	
	return exposed_corners

func should_cull_triangle(pos: Vector3i, neighbors: Dictionary, face_center: Vector3, 
						  face_normal: Vector3, exposed_corners: Array, disable_all_culling: bool) -> bool:
	var NeighborDir = MeshGenerator.NeighborDir
	var interior_margin = 0.15
	var s = grid_size
	
	# Only cull side faces in the BOTTOM HALF (y < grid_size * 0.5)
	var is_bottom_half = face_center.y < s * 0.5
	
	# West side - only cull bottom half
	if is_bottom_half and neighbors[NeighborDir.WEST] != -1 and not _should_render_vertical_face(pos, pos + Vector3i(-1, 0, 0)):
		if face_center.x < interior_margin:
			var is_near_corner = ("NW" in exposed_corners and face_center.z < s * 0.5) or \
								 ("SW" in exposed_corners and face_center.z > s * 0.5)
			if not is_near_corner and face_normal.x < -0.7:
				return true
	
	# East side - only cull bottom half
	if is_bottom_half and neighbors[NeighborDir.EAST] != -1 and not _should_render_vertical_face(pos, pos + Vector3i(1, 0, 0)):
		if face_center.x > s - interior_margin:
			var is_near_corner = ("NE" in exposed_corners and face_center.z < s * 0.5) or \
								 ("SE" in exposed_corners and face_center.z > s * 0.5)
			if not is_near_corner and face_normal.x > 0.7:
				return true
	
	# Bottom face - always cull if neighbor below
	if neighbors[NeighborDir.DOWN] != -1 and not _should_render_vertical_face(pos, pos + Vector3i(0, -1, 0)):
		if face_center.y < interior_margin and face_normal.y < -0.7:
			return true
	
	# Top face - only cull if no disable_all_culling
	if neighbors[NeighborDir.UP] != -1 and not _should_render_vertical_face(pos, pos + Vector3i(0, 1, 0)):
		if face_center.y > s - interior_margin and face_normal.y > 0.7:
			if not disable_all_culling:
				return true
	
	# North side - only cull bottom half
	if is_bottom_half and neighbors[NeighborDir.NORTH] != -1 and not _should_render_vertical_face(pos, pos + Vector3i(0, 0, -1)):
		if face_center.z < interior_margin:
			var is_near_corner = ("NW" in exposed_corners and face_center.x < s * 0.5) or \
								 ("NE" in exposed_corners and face_center.x > s * 0.5)
			if not is_near_corner and face_normal.z < -0.7:
				return true
	
	# South side - only cull bottom half
	if is_bottom_half and neighbors[NeighborDir.SOUTH] != -1 and not _should_render_vertical_face(pos, pos + Vector3i(0, 0, 1)):
		if face_center.z > s - interior_margin:
			var is_near_corner = ("SW" in exposed_corners and face_center.x < s * 0.5) or \
								 ("SE" in exposed_corners and face_center.x > s * 0.5)
			if not is_near_corner and face_normal.z > 0.7:
				return true
	
	return false

func _should_render_vertical_face(current_pos: Vector3i, neighbor_pos: Vector3i) -> bool:
	if neighbor_pos not in tiles:
		return true
	var current_offset = tile_map.get_offset_for_y(current_pos.y)
	var neighbor_offset = tile_map.get_offset_for_y(neighbor_pos.y)
	return not current_offset.is_equal_approx(neighbor_offset)
