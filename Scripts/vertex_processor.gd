class_name VertexProcessor extends RefCounted

var tile_map: TileMap3D
var tiles: Dictionary
var grid_size: float

func setup(tilemap: TileMap3D, tiles_ref: Dictionary, grid_sz: float):
	tile_map = tilemap
	tiles = tiles_ref
	grid_size = grid_sz

func apply_slant_rotation(v: Vector3, slant_type: int) -> Vector3:
	var center = Vector3(grid_size * 0.5, 0, grid_size * 0.5)
	var relative = v - center
	
	var angle = -PI / 4.0 if slant_type == tile_map.SlantType.NW_SE else PI / 4.0
	var cos_a = cos(angle)
	var sin_a = sin(angle)
	var rotated = Vector3(
		relative.x * cos_a - relative.z * sin_a,
		relative.y,
		relative.x * sin_a + relative.z * cos_a
	)
	return rotated + center

func extend_slant_vertices(v: Vector3, pos: Vector3i, slant_type: int) -> Vector3:
	var result = v
	var s = grid_size
	
	# Check diagonal neighbors
	var nw_pos = pos + Vector3i(-1, 0, -1)
	var ne_pos = pos + Vector3i(1, 0, -1)
	var sw_pos = pos + Vector3i(-1, 0, 1)
	var se_pos = pos + Vector3i(1, 0, 1)
	
	var has_nw = (nw_pos in tiles and tile_map.get_tile_slant(nw_pos) == slant_type)
	var has_ne = (ne_pos in tiles and tile_map.get_tile_slant(ne_pos) == slant_type)
	var has_sw = (sw_pos in tiles and tile_map.get_tile_slant(sw_pos) == slant_type)
	var has_se = (se_pos in tiles and tile_map.get_tile_slant(se_pos) == slant_type)
	
	var extension_distance = s * 0.35
	
	match slant_type:
		tile_map.SlantType.NW_SE:
			if has_nw:
				var dist_to_diagonal = abs(v.x - v.z) / sqrt(2.0)
				var dist_along_diagonal = (v.x + v.z) / sqrt(2.0)
				if dist_to_diagonal < s * 0.3 and dist_along_diagonal < s * 0.6:
					result.x = v.x - extension_distance
					result.z = v.z - extension_distance
			if has_se:
				var dist_to_diagonal = abs(v.x - v.z) / sqrt(2.0)
				var dist_along_diagonal = (v.x + v.z) / sqrt(2.0)
				if dist_to_diagonal < s * 0.3 and dist_along_diagonal > s * 0.8:
					result.x = v.x + extension_distance
					result.z = v.z + extension_distance
		
		tile_map.SlantType.NE_SW:
			if has_ne:
				var dist_to_diagonal = abs((s - v.x) - v.z) / sqrt(2.0)
				var dist_along_diagonal = ((s - v.x) + v.z) / sqrt(2.0)
				if dist_to_diagonal < s * 0.3 and dist_along_diagonal < s * 0.6:
					result.x = v.x + extension_distance
					result.z = v.z - extension_distance
			if has_sw:
				var dist_to_diagonal = abs((s - v.x) - v.z) / sqrt(2.0)
				var dist_along_diagonal = ((s - v.x) + v.z) / sqrt(2.0)
				if dist_to_diagonal < s * 0.3 and dist_along_diagonal > s * 0.8:
					result.x = v.x - extension_distance
					result.z = v.z + extension_distance
	
	return result

func extend_to_boundary_if_neighbor(v: Vector3, neighbors: Dictionary, threshold: float, pos: Vector3i) -> Vector3:
	var result = v
	var NeighborDir = MeshGenerator.NeighborDir
	
	var near_x_min = v.x < threshold
	var near_x_max = v.x > grid_size - threshold
	var near_y_max = v.y > grid_size - threshold
	var near_z_min = v.z < threshold
	var near_z_max = v.z > grid_size - threshold
	
	# Block above: extend Y but preserve X/Z for top surface
	if neighbors[NeighborDir.UP] != -1:
		var current_offset = tile_map.get_offset_for_y(pos.y)
		var neighbor_offset = tile_map.get_offset_for_y(pos.y + 1)
		
		if current_offset.is_equal_approx(neighbor_offset):
			if near_y_max:
				result.y = grid_size
			
			var is_side_vertex = not near_y_max or (near_y_max and (near_x_min or near_x_max or near_z_min or near_z_max))
			
			if is_side_vertex:
				if near_x_min:
					result.x = 0
				elif near_x_max:
					result.x = grid_size
				if near_z_min:
					result.z = 0
				elif near_z_max:
					result.z = grid_size
			return result
	
	# Block below: extend bottom
	if neighbors[NeighborDir.DOWN] != -1 and v.y < grid_size * 0.5:
		var current_offset = tile_map.get_offset_for_y(pos.y)
		var neighbor_offset = tile_map.get_offset_for_y(pos.y - 1)
		var offset_diff = current_offset - neighbor_offset
		result.y = -abs(offset_diff.y)
	
	# Standard boundary extension
	if near_x_min and neighbors[NeighborDir.WEST] != -1:
		if not (near_z_min and neighbors[NeighborDir.NORTH] != -1) and not (near_z_max and neighbors[NeighborDir.SOUTH] != -1):
			result.x = 0
	elif near_x_max and neighbors[NeighborDir.EAST] != -1:
		if not (near_z_min and neighbors[NeighborDir.NORTH] != -1) and not (near_z_max and neighbors[NeighborDir.SOUTH] != -1):
			result.x = grid_size
	
	if near_y_max and neighbors[NeighborDir.UP] != -1:
		result.y = grid_size
	
	if near_z_min and neighbors[NeighborDir.NORTH] != -1:
		if not (near_x_min and neighbors[NeighborDir.WEST] != -1) and not (near_x_max and neighbors[NeighborDir.EAST] != -1):
			result.z = 0
	elif near_z_max and neighbors[NeighborDir.SOUTH] != -1:
		if not (near_x_min and neighbors[NeighborDir.WEST] != -1) and not (near_x_max and neighbors[NeighborDir.EAST] != -1):
			result.z = grid_size
	
	return result
