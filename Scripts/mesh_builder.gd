class_name MeshBuilder extends RefCounted

var tile_map: TileMap3D

func setup(tilemap: TileMap3D):
	tile_map = tilemap

func build_final_mesh(triangles_by_surface: Dictionary, tile_type: int, base_mesh: ArrayMesh) -> ArrayMesh:
	var final_mesh = ArrayMesh.new()
	var SurfaceRole = MeshGenerator.SurfaceRole
	var MeshArrays = MeshGenerator.MeshArrays

	for surf_type in [SurfaceRole.TOP, SurfaceRole.SIDES, SurfaceRole.BOTTOM]:
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

func generate_simple_tile_mesh(tile_type: int, neighbors: Dictionary[MeshGenerator.NeighborDir, int], grid_size: float, cull_top: bool = false, pos: Vector3i = Vector3i.ZERO) -> ArrayMesh:
	var s: float = grid_size
	var NeighborDir := MeshGenerator.NeighborDir
	var SurfaceRole := MeshGenerator.SurfaceRole

	# Collect geometry per surface role separately so the export optimizer
	# can look up TOP/SIDES/BOTTOM by role name rather than getting everything
	# dumped into a single surface.
	var top_v    := PackedVector3Array(); var top_n    := PackedVector3Array()
	var top_uv   := PackedVector2Array(); var top_i    := PackedInt32Array()
	var sides_v  := PackedVector3Array(); var sides_n  := PackedVector3Array()
	var sides_uv := PackedVector2Array(); var sides_i  := PackedInt32Array()
	var bot_v    := PackedVector3Array(); var bot_n    := PackedVector3Array()
	var bot_uv   := PackedVector2Array(); var bot_i    := PackedInt32Array()

	var has_n := neighbors[NeighborDir.NORTH] != -1
	var has_s := neighbors[NeighborDir.SOUTH] != -1
	var has_e := neighbors[NeighborDir.EAST]  != -1
	var has_w := neighbors[NeighborDir.WEST]  != -1

	# Helper: is this neighbor type a bulge (custom mesh with no tile above it)?
	var _is_bulge = func(neighbor_type: int, neighbor_pos: Vector3i) -> bool:
		if neighbor_type == -1:
			return false
		var is_custom: bool = (neighbor_type in tile_map.custom_meshes) or \
							  (neighbor_type == MeshGenerator.TILE_TYPE_STAIRS)
		if not is_custom:
			return false
		return (neighbor_pos + Vector3i(0,1,0)) not in tile_map.tiles

	# Helper: should a simple tile's side face toward a bulge neighbor be shown?
	# Rule: show if the bulge has <= 1 neighbors in the two perpendicular directions
	# (left and right relative to the face). A bulge flanked on both sides is enclosed
	# and the face behind it is not visible; a bulge with one or no flank neighbors
	# leaves the face exposed.
	var _bulge_side_visible = func(bulge_pos: Vector3i, perp_a: Vector3i, perp_b: Vector3i) -> bool:
		var count: int = 0
		if (bulge_pos + perp_a) in tile_map.tiles: count += 1
		if (bulge_pos + perp_b) in tile_map.tiles: count += 1
		return count <= 1

	# Perpendicular offsets for each face direction
	var n_perps := [Vector3i(1,0,0),  Vector3i(-1,0,0)]
	var s_perps := [Vector3i(1,0,0),  Vector3i(-1,0,0)]
	var e_perps := [Vector3i(0,0,-1), Vector3i(0,0,1)]
	var w_perps := [Vector3i(0,0,-1), Vector3i(0,0,1)]

	# Neighbor positions
	var n_pos := pos + Vector3i(0,0,-1)
	var s_pos := pos + Vector3i(0,0,1)
	var e_pos := pos + Vector3i(1,0,0)
	var w_pos := pos + Vector3i(-1,0,0)
	var up_pos := pos + Vector3i(0,1,0)

	# TOP — show when UP is absent, OR UP is a bulge where:
	#   1. The bulge above has at least one non-bulge cardinal (not fully enclosed above), AND
	#   2. This simple tile has at least one open cardinal (absent or bulge neighbor),
	#      giving a viewing angle into the strip between the top and the bulge above.
	var up_type: int = neighbors[NeighborDir.UP]
	var show_top: bool = false
	if up_type == -1:
		show_top = true
	elif _is_bulge.call(up_type, up_pos):
		# Condition 1: bulge above has at least one non-bulge cardinal
		var bulge_exposed: bool = false
		var bu := up_pos
		for bc in [bu + Vector3i(0,0,-1), bu + Vector3i(0,0,1), bu + Vector3i(1,0,0), bu + Vector3i(-1,0,0)]:
			var bc_is_bulge: bool = (bc in tile_map.tiles) and ((bc + Vector3i(0,1,0)) not in tile_map.tiles)
			if not bc_is_bulge:
				bulge_exposed = true
				break
		# Condition 2: there exists a direction where BOTH the simple tile's cardinal
		# is open (absent or bulge) AND the bulge above's same-direction cardinal is
		# non-bulge. The viewing angle must align on the same side.
		if bulge_exposed:
			for dir_offset in [Vector3i(0,0,-1), Vector3i(0,0,1), Vector3i(1,0,0), Vector3i(-1,0,0)]:
				var tile_cc: Vector3i = pos + dir_offset
				var tile_cc_is_flat: bool = (tile_cc in tile_map.tiles) and ((tile_cc + Vector3i(0,1,0)) in tile_map.tiles)
				if tile_cc_is_flat:
					continue  # This side of the simple tile is sealed
				var bulge_cc: Vector3i = bu + dir_offset
				var bulge_cc_is_bulge: bool = (bulge_cc in tile_map.tiles) and ((bulge_cc + Vector3i(0,1,0)) not in tile_map.tiles)
				if not bulge_cc_is_bulge:
					show_top = true
					break
	if show_top and not cull_top:
		_add_quad(top_v, top_i, top_n, top_uv,
			Vector3(0,s,0), Vector3(s,s,0), Vector3(s,s,s), Vector3(0,s,s), Vector3(0,1,0))

	# SIDES — show when neighbor absent, OR neighbor is a bulge with <=1 perpendicular neighbors
	if not has_n or (_is_bulge.call(neighbors[NeighborDir.NORTH], n_pos) and _bulge_side_visible.call(n_pos, n_perps[0], n_perps[1])):
		_add_quad(sides_v, sides_i, sides_n, sides_uv,
			Vector3(0,0,0), Vector3(s,0,0), Vector3(s,s,0), Vector3(0,s,0), Vector3(0,0,-1))
	if not has_s or (_is_bulge.call(neighbors[NeighborDir.SOUTH], s_pos) and _bulge_side_visible.call(s_pos, s_perps[0], s_perps[1])):
		_add_quad(sides_v, sides_i, sides_n, sides_uv,
			Vector3(s,0,s), Vector3(0,0,s), Vector3(0,s,s), Vector3(s,s,s), Vector3(0,0,1))
	if not has_e or (_is_bulge.call(neighbors[NeighborDir.EAST], e_pos) and _bulge_side_visible.call(e_pos, e_perps[0], e_perps[1])):
		_add_quad(sides_v, sides_i, sides_n, sides_uv,
			Vector3(s,0,0), Vector3(s,0,s), Vector3(s,s,s), Vector3(s,s,0), Vector3(1,0,0))
	if not has_w or (_is_bulge.call(neighbors[NeighborDir.WEST], w_pos) and _bulge_side_visible.call(w_pos, w_perps[0], w_perps[1])):
		_add_quad(sides_v, sides_i, sides_n, sides_uv,
			Vector3(0,0,s), Vector3(0,0,0), Vector3(0,s,0), Vector3(0,s,s), Vector3(-1,0,0))
	# BOTTOM
	if neighbors[NeighborDir.DOWN] == -1:
		_add_quad(bot_v, bot_i, bot_n, bot_uv,
			Vector3(0,0,s), Vector3(s,0,s), Vector3(s,0,0), Vector3(0,0,0), Vector3(0,-1,0))

	var mesh := ArrayMesh.new()

	# Emit each role as its own named surface. Skip empty ones.
	var role_data := [
		[top_v,   top_i,   top_n,   top_uv,   SurfaceRole.TOP],
		[sides_v, sides_i, sides_n, sides_uv, SurfaceRole.SIDES],
		[bot_v,   bot_i,   bot_n,   bot_uv,   SurfaceRole.BOTTOM],
	]
	for rd in role_data:
		var verts: PackedVector3Array = rd[0]
		if verts.size() == 0:
			continue
		var sa: Array = []
		sa.resize(Mesh.ARRAY_MAX)
		sa[Mesh.ARRAY_VERTEX] = verts
		sa[Mesh.ARRAY_INDEX]  = rd[1]
		sa[Mesh.ARRAY_NORMAL] = rd[2]
		sa[Mesh.ARRAY_TEX_UV] = rd[3]
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, sa)
		var surf_idx: int = mesh.get_surface_count() - 1
		var role: int = rd[4]
		mesh.surface_set_name(surf_idx, str(role))
		# Read material from the custom mesh's corresponding surface.
		# custom_materials holds white placeholders — the real textures live on
		# custom_meshes surfaces. flip_mesh_normals and align_mesh_to_grid both
		# rebuild the mesh preserving material and surface ORDER but stripping names,
		# so we match by index (0=Top, 1=Sides, 2=Bottom) not by name.
		var mat: Material = null
		if tile_type in tile_map.custom_meshes:
			var src: ArrayMesh = tile_map.custom_meshes[tile_type]
			if role < src.get_surface_count():
				mat = src.surface_get_material(role)
		if mat:
			mesh.surface_set_material(surf_idx, mat)

	return mesh


func _add_quad(verts: PackedVector3Array, indices: PackedInt32Array,
			  normals: PackedVector3Array, uvs: PackedVector2Array,
			  v1: Vector3, v2: Vector3, v3: Vector3, v4: Vector3, normal: Vector3):
	var start = verts.size()
	verts.append_array([v1, v2, v3, v4])
	normals.append_array([normal, normal, normal, normal])
	uvs.append_array([Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)])
	indices.append_array([start, start + 1, start + 2, start, start + 2, start + 3])
