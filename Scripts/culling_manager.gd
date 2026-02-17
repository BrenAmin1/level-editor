class_name CullingManager extends RefCounted

var tile_map: TileMap3D
var tiles: Dictionary
var grid_size: float
var batch_mode_skip_culling: bool = false
var corner_keeps: Dictionary = {}  # Track which corners are kept: {pos_str: {corner_desc: true}}
var positions_processed: Dictionary = {}  # Track all positions that went through culling

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

func should_cull_stair_face(face_normal: Vector3, neighbors: Dictionary, rotation_degrees: float) -> bool:
	"""
	Cull the solid side and back faces of a stair mesh based on neighbors.
	
	Stairs have three fully-solid faces that can be culled:
	  - Left side   (West face of the unrotated mesh, normal -X)
	  - Right side  (East face of the unrotated mesh, normal +X)
	  - Back face   (South face of the unrotated mesh, normal +Z)
	
	These map to world-space directions after the stair's rotation is applied.
	We rotate the face normal back into the stair's local space, then check
	whether the corresponding neighbor slot is occupied.
	
	The bottom face is always culled (it's on the ground).
	The front and top step faces are never culled (they're always visible).
	"""
	var NeighborDir = MeshGenerator.NeighborDir

	# Bottom face — always hidden (flush with ground plane)
	if face_normal.y < -0.7:
		return true

	# Only side/back faces are candidates for culling.
	# Top-facing normals (step tops) and front-facing step risers are never culled.
	if face_normal.y > 0.1:
		return false  # Step top surface — never cull

	# Rotate the world-space face normal back to stair local space
	# so we can test against the canonical left/right/back directions.
	var local_normal = _rotate_normal_to_local(face_normal, rotation_degrees)

	# Left side of stairs (local -X)
	if local_normal.x < -0.7:
		return neighbors[NeighborDir.WEST] != -1

	# Right side of stairs (local +X)
	if local_normal.x > 0.7:
		return neighbors[NeighborDir.EAST] != -1

	# Back of stairs (local +Z, the tall solid back wall)
	if local_normal.z > 0.7:
		return neighbors[NeighborDir.SOUTH] != -1

	# Front / step risers (local -Z) — never cull, always visible
	return false


func _rotate_normal_to_local(world_normal: Vector3, rotation_degrees: float) -> Vector3:
	"""Rotate a world-space normal back into stair-local space (inverse of stair rotation)."""
	var angle_rad = deg_to_rad(-rotation_degrees)  # Inverse rotation
	var cos_a = cos(angle_rad)
	var sin_a = sin(angle_rad)
	# Rotate around Y axis
	return Vector3(
		world_normal.x * cos_a - world_normal.z * sin_a,
		world_normal.y,
		world_normal.x * sin_a + world_normal.z * cos_a
	)


func should_cull_triangle(pos: Vector3i, neighbors: Dictionary, face_center: Vector3, 
						  face_normal: Vector3, exposed_corners: Array, _disable_all_culling: bool, is_fully_enclosed: bool = false) -> bool:
	if batch_mode_skip_culling:
		return false
	
	# Track that we processed this position
	var pos_str = str(pos)
	positions_processed[pos_str] = true
	
	var NeighborDir = MeshGenerator.NeighborDir
	
	# Debug flag - set to true to track corner keeps
	var DEBUG_CULLING = true
	var DEBUG_INSIDE_TILES = false  # Turn off verbose debug
	
	# Check if this cube has a cube on top
	var has_cube_above = neighbors[NeighborDir.UP] != -1
	
	# Use the PRE-CAPTURED is_fully_enclosed status
	# (No longer checking tiles dictionary here - it's done before threading)
	
	# If this is a fully enclosed inside tile, aggressively cull everything
	# (Even if next to stairs - we can't see inside anyway)
	if is_fully_enclosed:
		if DEBUG_INSIDE_TILES:
			var face_type = "UNKNOWN"
			if face_normal.x < -0.7:
				face_type = "WEST"
			elif face_normal.x > 0.7:
				face_type = "EAST"
			elif face_normal.z < -0.7:
				face_type = "NORTH"
			elif face_normal.z > 0.7:
				face_type = "SOUTH"
			elif face_normal.y > 0.7:
				face_type = "TOP"
			elif face_normal.y < -0.7:
				face_type = "BOTTOM"
			print("  [CULLING] ", face_type, " face at ", pos, " (inside tile)")
		
		# Cull all side faces
		if abs(face_normal.x) > 0.7 or abs(face_normal.z) > 0.7:
			return true
		# Cull top faces
		if face_normal.y > 0.7:
			return true
		# Cull bottom faces if there's a tile below
		if face_normal.y < -0.7:
			if neighbors[NeighborDir.DOWN] != -1:
				return true
	
	# Otherwise, use normal culling logic with bulge handling
	
	# STAIRS CONSTANT
	var TILE_TYPE_STAIRS = 5
	
	# West face (normal pointing in -X direction)
	if face_normal.x < -0.7:
		# Check if this face is part of ANY exposed corner
		var is_part_of_nw_corner = NeighborDir.DIAGONAL_NW in exposed_corners
		var is_part_of_sw_corner = NeighborDir.DIAGONAL_SW in exposed_corners
		
		# If this face is part of an exposed corner, DON'T cull ANY of it
		if is_part_of_nw_corner or is_part_of_sw_corner:
			if DEBUG_CULLING:
				if is_part_of_nw_corner:
					_track_corner_keep(pos, "WEST at NW")
				if is_part_of_sw_corner:
					_track_corner_keep(pos, "WEST at SW")
			return false  # Keep the ENTIRE face
		
		# STAIRS CHECK: If west neighbor is stairs, never cull this face
		if neighbors[NeighborDir.WEST] == TILE_TYPE_STAIRS:
			return false
		
		# Otherwise, apply normal face culling
		if neighbors[NeighborDir.WEST] != -1:
			var neighbor_pos = pos + Vector3i(-1, 0, 0)
			if neighbor_pos.y == pos.y:
				if not _should_render_side_face(face_center, has_cube_above):
					return true
			elif not _should_render_vertical_face(pos, neighbor_pos):
				return true
	
	# East face (normal pointing in +X direction)
	if face_normal.x > 0.7:
		# Check if this face is part of ANY exposed corner
		var is_part_of_ne_corner = NeighborDir.DIAGONAL_NE in exposed_corners
		var is_part_of_se_corner = NeighborDir.DIAGONAL_SE in exposed_corners
		
		# If this face is part of an exposed corner, DON'T cull ANY of it
		if is_part_of_ne_corner or is_part_of_se_corner:
			if DEBUG_CULLING:
				if is_part_of_ne_corner:
					_track_corner_keep(pos, "EAST at NE")
				if is_part_of_se_corner:
					_track_corner_keep(pos, "EAST at SE")
			return false  # Keep the ENTIRE face
		
		# STAIRS CHECK: If east neighbor is stairs, never cull this face
		if neighbors[NeighborDir.EAST] == TILE_TYPE_STAIRS:
			return false
		
		# Otherwise, apply normal face culling
		if neighbors[NeighborDir.EAST] != -1:
			var neighbor_pos = pos + Vector3i(1, 0, 0)
			if neighbor_pos.y == pos.y:
				if not _should_render_side_face(face_center, has_cube_above):
					return true
			elif not _should_render_vertical_face(pos, neighbor_pos):
				return true
	
	# North face (normal pointing in -Z direction)
	if face_normal.z < -0.7:
		# Check if this face is part of ANY exposed corner
		var is_part_of_nw_corner = NeighborDir.DIAGONAL_NW in exposed_corners
		var is_part_of_ne_corner = NeighborDir.DIAGONAL_NE in exposed_corners
		
		# If this face is part of an exposed corner, DON'T cull ANY of it
		if is_part_of_nw_corner or is_part_of_ne_corner:
			if DEBUG_CULLING:
				if is_part_of_nw_corner:
					_track_corner_keep(pos, "NORTH at NW")
				if is_part_of_ne_corner:
					_track_corner_keep(pos, "NORTH at NE")
			return false  # Keep the ENTIRE face
		
		# STAIRS CHECK: If north neighbor is stairs, never cull this face
		if neighbors[NeighborDir.NORTH] == TILE_TYPE_STAIRS:
			return false
		
		# Otherwise, apply normal face culling
		if neighbors[NeighborDir.NORTH] != -1:
			var neighbor_pos = pos + Vector3i(0, 0, -1)
			if neighbor_pos.y == pos.y:
				if not _should_render_side_face(face_center, has_cube_above):
					return true
			elif not _should_render_vertical_face(pos, neighbor_pos):
				return true
	
	# South face (normal pointing in +Z direction)
	if face_normal.z > 0.7:
		# Check if this face is part of ANY exposed corner
		var is_part_of_sw_corner = NeighborDir.DIAGONAL_SW in exposed_corners
		var is_part_of_se_corner = NeighborDir.DIAGONAL_SE in exposed_corners
		
		# If this face is part of an exposed corner, DON'T cull ANY of it
		if is_part_of_sw_corner or is_part_of_se_corner:
			if DEBUG_CULLING:
				if is_part_of_sw_corner:
					_track_corner_keep(pos, "SOUTH at SW")
				if is_part_of_se_corner:
					_track_corner_keep(pos, "SOUTH at SE")
			return false  # Keep the ENTIRE face
		
		# STAIRS CHECK: If south neighbor is stairs, never cull this face
		if neighbors[NeighborDir.SOUTH] == TILE_TYPE_STAIRS:
			return false
		
		# Otherwise, apply normal face culling
		if neighbors[NeighborDir.SOUTH] != -1:
			var neighbor_pos = pos + Vector3i(0, 0, 1)
			if neighbor_pos.y == pos.y:
				if not _should_render_side_face(face_center, has_cube_above):
					return true
			elif not _should_render_vertical_face(pos, neighbor_pos):
				return true
	
	# Bottom face (normal pointing in -Y direction)
	if face_normal.y < -0.7:
		if neighbors[NeighborDir.DOWN] != -1:
			return true
	
	# Top face (normal pointing in +Y direction)
	if face_normal.y > 0.7:
		if neighbors[NeighborDir.UP] != -1:
			# Only cull the top face if it's below the bulge area
			# The bulge extends above standard grid height, so top faces in the bulge stay visible
			if not _face_is_in_bulge(face_center):
				return true
	
	return false

func _should_render_vertical_face(current_pos: Vector3i, neighbor_pos: Vector3i) -> bool:
	if neighbor_pos not in tiles:
		return true
	var current_offset = tile_map.get_offset_for_y(current_pos.y)
	var neighbor_offset = tile_map.get_offset_for_y(neighbor_pos.y)
	return not current_offset.is_equal_approx(neighbor_offset)

func _should_render_side_face(face_center: Vector3, has_cube_above: bool) -> bool:
	"""
	Determine if a side face should be rendered based on its height and whether the cube has another on top.
	
	Cubes with cubes on top have a bulge that extends above standard height.
	Cubes without cubes on top are normal height.
	
	A same-level neighbor can block:
	- For normal cubes: faces up to the standard grid height
	- For tall cubes (with cube above): only faces below the bulge area
	"""
	var blocking_height = grid_size * 0.5  # Halfway up the grid (0.5 for grid_size = 1.0)
	
	if has_cube_above:
		# This cube is taller (has bulge), so only faces above blocking_height should render
		return face_center.y > blocking_height
	else:
		# This cube is normal height, so all faces at normal height should be culled
		# Only render faces that extend above normal blocking (but this shouldn't happen for normal cubes)
		return false

func _face_is_in_bulge(face_center: Vector3) -> bool:
	"""
	Check if a top face is in the bulge area that extends above standard grid height.
	The bulge is the portion of the mesh above the standard grid_size.
	"""
	# For a grid_size of 1.0, the standard top is at y=0.5 (in local coords centered at origin)
	# The bulge extends beyond this
	# Looking at the OBJ, top vertices go up to ~0.5, so faces above ~0.4 are in the bulge
	var bulge_threshold = grid_size * 0.4
	return face_center.y > bulge_threshold

func _track_corner_keep(pos: Vector3i, corner_desc: String):
	var pos_str = str(pos)
	if not corner_keeps.has(pos_str):
		corner_keeps[pos_str] = {}  # Use dictionary as a set
	corner_keeps[pos_str][corner_desc] = true  # Only track unique corner types

func print_corner_summary():
	print("\n--- Corner Keep Summary ---")
	print("Total positions processed: ", positions_processed.size())
	
	if corner_keeps.is_empty():
		print("No corners kept at any position!")
	else:
		print("\nPositions WITH corners kept:")
		var positions = corner_keeps.keys()
		positions.sort()
		for pos_str in positions:
			var corner_types = corner_keeps[pos_str].keys()  # Get unique corner types
			corner_types.sort()
			print("  Pos:", pos_str, " → ", corner_types.size(), " unique corner(s): ", corner_types)
	
	# Show positions that were processed but have NO corners
	var all_positions = positions_processed.keys()
	all_positions.sort()
	var positions_without_corners = []
	for pos_str in all_positions:
		if not corner_keeps.has(pos_str):
			positions_without_corners.append(pos_str)
	
	if not positions_without_corners.is_empty():
		print("\nPositions WITHOUT any corners kept:")
		for pos_str in positions_without_corners:
			print("  Pos:", pos_str, " → 0 corners")
	
	print("--- End Summary ---\n")

func _is_face_at_corner(face_center: Vector3, face_normal: Vector3) -> bool:
	"""
	Check if a face is positioned at a corner of the cube.
	Corner faces are those VERY close to the actual corner vertices.
	
	The mesh vertices are in range -0.5 to 0.5, so we check against those bounds.
	"""
	var corner_threshold = 0.4  # Must be within 0.15 units of the edge (0.35 to 0.5)
	
	# For each cardinal direction, check if face is very close to the perpendicular edges
	# West-facing or East-facing: check if near north or south edges
	if abs(face_normal.x) > 0.7:
		# Near north edge (z close to -0.5) or south edge (z close to 0.5)
		return abs(face_center.z) > corner_threshold
	
	# North-facing or South-facing: check if near west or east edges  
	if abs(face_normal.z) > 0.7:
		# Near west edge (x close to -0.5) or east edge (x close to 0.5)
		return abs(face_center.x) > corner_threshold
	
	return false

func _corner_is_exposed(face_center: Vector3, face_normal: Vector3, exposed_corners: Array) -> bool:
	"""
	Check if the corner this face is at corresponds to an exposed diagonal.
	
	Mesh coordinates are -0.5 to 0.5, with 0,0 at center.
	"""
	var NeighborDir = MeshGenerator.NeighborDir
	
	# Determine which corner this face is at based on its position and normal
	# West-facing faces (normal pointing -X)
	if face_normal.x < -0.7:
		if face_center.z < 0:  # North side (negative Z)
			return NeighborDir.DIAGONAL_NW in exposed_corners
		else:  # South side (positive Z)
			return NeighborDir.DIAGONAL_SW in exposed_corners
	
	# East-facing faces (normal pointing +X)
	if face_normal.x > 0.7:
		if face_center.z < 0:  # North side
			return NeighborDir.DIAGONAL_NE in exposed_corners
		else:  # South side
			return NeighborDir.DIAGONAL_SE in exposed_corners
	
	# North-facing faces (normal pointing -Z)
	if face_normal.z < -0.7:
		if face_center.x < 0:  # West side (negative X)
			return NeighborDir.DIAGONAL_NW in exposed_corners
		else:  # East side (positive X)
			return NeighborDir.DIAGONAL_NE in exposed_corners
	
	# South-facing faces (normal pointing +Z)
	if face_normal.z > 0.7:
		if face_center.x < 0:  # West side
			return NeighborDir.DIAGONAL_SW in exposed_corners
		else:  # East side
			return NeighborDir.DIAGONAL_SE in exposed_corners
	
	return false
