class_name VertexProcessor extends RefCounted

var tile_map: TileMap3D
var tiles: Dictionary
var grid_size: float

func setup(tilemap: TileMap3D, tiles_ref: Dictionary, grid_sz: float):
	tile_map = tilemap
	tiles = tiles_ref
	grid_size = grid_sz


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
	
	# Standard boundary extension - SIMPLIFIED to allow corners
	if near_x_min and neighbors[NeighborDir.WEST] != -1:
		result.x = 0
	elif near_x_max and neighbors[NeighborDir.EAST] != -1:
		result.x = grid_size
	
	if near_y_max and neighbors[NeighborDir.UP] != -1:
		result.y = grid_size
	
	if near_z_min and neighbors[NeighborDir.NORTH] != -1:
		result.z = 0
	elif near_z_max and neighbors[NeighborDir.SOUTH] != -1:
		result.z = grid_size
	
	return result
