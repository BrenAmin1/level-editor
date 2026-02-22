class_name MeshBuilder extends RefCounted

var tile_map: TileMap3D

func setup(tilemap: TileMap3D):
	tile_map = tilemap

func build_final_mesh(triangles_by_surface: Dictionary, tile_type: int, base_mesh: ArrayMesh) -> ArrayMesh:
	var final_mesh = ArrayMesh.new()
	var SurfaceType = MeshGenerator.SurfaceType
	var MeshArrays = MeshGenerator.MeshArrays

	for surf_type in [SurfaceType.TOP, SurfaceType.SIDES, SurfaceType.BOTTOM]:
		var surf_data = triangles_by_surface[surf_type]

		if surf_data[MeshArrays.VERTICES].size() > 0:
			var surface_array = []
			surface_array.resize(Mesh.ARRAY_MAX)
			surface_array[Mesh.ARRAY_VERTEX] = surf_data[MeshArrays.VERTICES]
			surface_array[Mesh.ARRAY_NORMAL] = surf_data[MeshArrays.NORMALS]
			if surf_data[MeshArrays.UVS].size() > 0:
				surface_array[Mesh.ARRAY_TEX_UV] = surf_data[MeshArrays.UVS]
			surface_array[Mesh.ARRAY_INDEX] = surf_data[MeshArrays.INDICES]

			final_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface_array)
			var surf_idx = final_mesh.get_surface_count() - 1
			# Tag with SurfaceRole int so apply_palette_material_to_mesh finds TOP
			# by role rather than assuming index 0 (invalid when TOP is culled away).
			final_mesh.surface_set_name(surf_idx, str(surf_type))

			var material = null
			if tile_type in tile_map.custom_materials and surf_type < tile_map.custom_materials[tile_type].size():
				material = tile_map.custom_materials[tile_type][surf_type]
			if not material:
				# Look up by name — surface indices in base_mesh are NOT stable
				# (TOP is culled away when covered, shifting SIDES to index 0).
				var role_name = str(surf_type)
				for i in base_mesh.get_surface_count():
					if base_mesh.surface_get_name(i) == role_name:
						material = base_mesh.surface_get_material(i)
						break
			if material:
				final_mesh.surface_set_material(surf_idx, material)

	return final_mesh

func generate_simple_tile_mesh(tile_type: int, neighbors: Dictionary, grid_size: float) -> ArrayMesh:
	var surface_array = []
	surface_array.resize(Mesh.ARRAY_MAX)

	var verts = PackedVector3Array()
	var indices = PackedInt32Array()
	var normals = PackedVector3Array()
	var uvs = PackedVector2Array()
	var s = grid_size
	var NeighborDir = MeshGenerator.NeighborDir

	if neighbors[NeighborDir.NORTH] == -1:
		_add_quad(verts, indices, normals, uvs,
			Vector3(0, 0, 0), Vector3(s, 0, 0), Vector3(s, s, 0), Vector3(0, s, 0), Vector3(0, 0, -1))
	if neighbors[NeighborDir.SOUTH] == -1:
		_add_quad(verts, indices, normals, uvs,
			Vector3(s, 0, s), Vector3(0, 0, s), Vector3(0, s, s), Vector3(s, s, s), Vector3(0, 0, 1))
	if neighbors[NeighborDir.EAST] == -1:
		_add_quad(verts, indices, normals, uvs,
			Vector3(s, 0, 0), Vector3(s, 0, s), Vector3(s, s, s), Vector3(s, s, 0), Vector3(1, 0, 0))
	if neighbors[NeighborDir.WEST] == -1:
		_add_quad(verts, indices, normals, uvs,
			Vector3(0, 0, s), Vector3(0, 0, 0), Vector3(0, s, 0), Vector3(0, s, s), Vector3(-1, 0, 0))
	if neighbors[NeighborDir.UP] == -1:
		_add_quad(verts, indices, normals, uvs,
			Vector3(0, s, 0), Vector3(s, s, 0), Vector3(s, s, s), Vector3(0, s, s), Vector3(0, 1, 0))
	if neighbors[NeighborDir.DOWN] == -1:
		_add_quad(verts, indices, normals, uvs,
			Vector3(0, 0, s), Vector3(s, 0, s), Vector3(s, 0, 0), Vector3(0, 0, 0), Vector3(0, -1, 0))

	surface_array[Mesh.ARRAY_VERTEX] = verts
	surface_array[Mesh.ARRAY_INDEX] = indices
	surface_array[Mesh.ARRAY_NORMAL] = normals
	surface_array[Mesh.ARRAY_TEX_UV] = uvs

	var mesh = ArrayMesh.new()
	if verts.size() > 0:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface_array)
		# Single merged surface — tag TOP role so palette override lands correctly.
		mesh.surface_set_name(0, str(MeshGenerator.SurfaceRole.TOP))
		var material = StandardMaterial3D.new()
		if tile_type == 0:
			material.albedo_color = Color(0.7, 0.7, 0.7)
		elif tile_type == 1:
			material.albedo_color = Color(0.8, 0.5, 0.3)
		mesh.surface_set_material(0, material)

	return mesh

func _add_quad(verts: PackedVector3Array, indices: PackedInt32Array,
			  normals: PackedVector3Array, uvs: PackedVector2Array,
			  v1: Vector3, v2: Vector3, v3: Vector3, v4: Vector3, normal: Vector3):
	var start = verts.size()
	verts.append_array([v1, v2, v3, v4])
	normals.append_array([normal, normal, normal, normal])
	uvs.append_array([Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)])
	indices.append_array([start, start + 1, start + 2, start, start + 2, start + 3])
