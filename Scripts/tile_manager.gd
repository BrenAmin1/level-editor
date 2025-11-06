class_name TileManager extends RefCounted



func world_to_grid(pos: Vector3) -> Vector3i:
	return Vector3i(
		floori(pos.x / grid_size),
		floori(pos.y / grid_size),
		floori(pos.z / grid_size)
	)


func grid_to_world(pos: Vector3i) -> Vector3:
	var offset = get_offset_for_y(pos.y)
	return Vector3(pos.x * grid_size + offset.x, pos.y * grid_size, pos.z * grid_size + offset.y)

func place_tile(pos: Vector3i, tile_type: int):
	tiles[pos] = tile_type
	
	update_tile_mesh(pos)
	for offset in [
		Vector3i(1,0,0), Vector3i(-1,0,0),
		Vector3i(0,1,0), Vector3i(0,-1,0),
		Vector3i(0,0,1), Vector3i(0,0,-1)
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
	
	for offset in [
		Vector3i(1,0,0), Vector3i(-1,0,0),
		Vector3i(0,1,0), Vector3i(0,-1,0),
		Vector3i(0,0,1), Vector3i(0,0,-1)
	]:
		var neighbor_pos = pos + offset
		if neighbor_pos in tiles:
			update_tile_mesh(neighbor_pos)

func has_tile(pos: Vector3i) -> bool:
	return pos in tiles

func get_tile_type(pos: Vector3i) -> int:
	return tiles.get(pos, -1)

func update_tile_mesh(pos: Vector3i):
	if not parent_node:
		return
	
	var tile_type = tiles[pos]
	
	# Use custom mesh if available, otherwise generate default
	var mesh: ArrayMesh
	if tile_type in custom_meshes:
		var neighbors = get_neighbors(pos)
		mesh = generate_custom_tile_mesh(pos, tile_type, neighbors)
	else:
		var neighbors = get_neighbors(pos)
		mesh = generate_tile_mesh(pos, tile_type, neighbors)
	
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

func get_neighbors(pos: Vector3i) -> Dictionary:
	var neighbors = {}
	var directions = {
		"north": Vector3i(0, 0, -1),
		"south": Vector3i(0, 0, 1),
		"east": Vector3i(1, 0, 0),
		"west": Vector3i(-1, 0, 0),
		"up": Vector3i(0, 1, 0),
		"down": Vector3i(0, -1, 0)
	}
	
	for dir_name in directions:
		var neighbor_pos = pos + directions[dir_name]
		neighbors[dir_name] = tiles.get(neighbor_pos, -1)
	
	return neighbors
