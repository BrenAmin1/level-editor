class_name RotationHandler extends RefCounted

var grid_size: float
var auto_rotation_enabled: bool = false  # Disabled for manual-only mode

func setup(grid_sz: float):
	grid_size = grid_sz

func get_rotation_for_tile(_tile_type: int, _neighbors: Dictionary, _pos: Vector3i = Vector3i.ZERO, _tiles: Dictionary = {}) -> float:
	# Manual rotation only - all auto-detection disabled
	# No auto-slant, no diagonal detection, no neighbor-based rotation
	return 0.0

# Keep the helper methods in case you want to re-enable later
func _get_half_bevel_rotation(neighbors: Dictionary) -> float:
	var NeighborDir = MeshGenerator.NeighborDir
	
	# Check which directions HAVE neighbors (solid interior)
	var has_north = neighbors[NeighborDir.NORTH] != -1
	var has_south = neighbors[NeighborDir.SOUTH] != -1
	var has_east = neighbors[NeighborDir.EAST] != -1
	var has_west = neighbors[NeighborDir.WEST] != -1
	
	var neighbor_count = int(has_north) + int(has_south) + int(has_east) + int(has_west)
	
	if neighbor_count == 0 or neighbor_count == 4:
		return 0.0
	
	# EDGE: One neighbor - face away from that neighbor
	if neighbor_count == 1:
		if has_north:
			return 180.0
		elif has_south:
			return 0.0
		elif has_east:
			return 270.0
		elif has_west:
			return 90.0
	
	# CORNER: Two adjacent neighbors - face away diagonally
	elif neighbor_count == 2:
		if has_north and has_west:
			return 45  # Interior NW, face SE
		elif has_north and has_east:
			return -225.0    # Interior NE, face SW
		elif has_south and has_west:
			return -45.0     # Interior SW, face NE
		elif has_south and has_east:
			return 225    # Interior SE, face NW
	
	# THREE neighbors: Face the only open side
	elif neighbor_count == 3:
		if not has_north:
			return 0.0
		elif not has_south:
			return 180.0
		elif not has_east:
			return 90.0
		elif not has_west:
			return 270.0
	
	return 0.0

func rotate_vertices_y(vertices: PackedVector3Array, angle_degrees: float) -> PackedVector3Array:
	if angle_degrees == 0.0:
		return vertices
	
	var angle_rad = deg_to_rad(angle_degrees)
	var cos_a = cos(angle_rad)
	var sin_a = sin(angle_rad)
	var center = Vector3(grid_size * 0.5, 0, grid_size * 0.5)
	
	var rotated = PackedVector3Array()
	for v in vertices:
		var relative = v - center
		rotated.append(Vector3(
			relative.x * cos_a - relative.z * sin_a,
			relative.y,
			relative.x * sin_a + relative.z * cos_a
		) + center)
	return rotated

func rotate_normals_y(normals: PackedVector3Array, angle_degrees: float) -> PackedVector3Array:
	if angle_degrees == 0.0:
		return normals
	
	var angle_rad = deg_to_rad(angle_degrees)
	var cos_a = cos(angle_rad)
	var sin_a = sin(angle_rad)
	
	var rotated = PackedVector3Array()
	for n in normals:
		rotated.append(Vector3(
			n.x * cos_a - n.z * sin_a,
			n.y,
			n.x * sin_a + n.z * cos_a
		))
	return rotated
