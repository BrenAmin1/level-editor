class_name MeshOptimizer extends RefCounted

# ============================================================================
# MESH OPTIMIZER
# ============================================================================
# In-editor mesh generation only. Export logic lives in GlbExporter.
#
# Responsibilities:
#   - generate_optimized_level_mesh()               single-surface, in-editor preview
#   - generate_optimized_level_mesh_multi_material() per-(tile_type, palette_index) surfaces
#   - Shared mesh-combining and vertex-welding helpers used by GlbExporter too
# ============================================================================

var tiles: Dictionary[Vector3i, int]
var custom_meshes: Dictionary[int, ArrayMesh]
var custom_materials: Dictionary[int, Array]
var tile_map: TileMap3D
var mesh_generator: MeshGenerator

# Positions whose top face should be culled (covered by a top-plane quad).
# Set by GlbExporter before calling the generate_* functions.
var _top_plane_cull: Dictionary[Vector3i, bool] = {}

# Optional progress callback — signature: func(done: int, total: int).
var progress_callback: Callable

# ============================================================================
# SETUP
# ============================================================================

func setup(tilemap: TileMap3D, tiles_ref: Dictionary[Vector3i, int],
		meshes_ref: Dictionary[int, ArrayMesh], generator: MeshGenerator,
		materials_ref: Dictionary[int, Array]) -> void:
	tile_map         = tilemap
	tiles            = tiles_ref
	custom_meshes    = meshes_ref
	mesh_generator   = generator
	custom_materials = materials_ref


func set_top_plane_cull_positions(positions: Dictionary[Vector3i, bool]) -> void:
	_top_plane_cull = positions


# ============================================================================
# CONSTANTS
# ============================================================================

# Snap precision for vertex welding.
# At grid_size = 1.0 this is 1/10 000th of a unit — safe for all tile features.
const WELD_EPSILON := 0.0001


# ============================================================================
# MESH GENERATION — IN-EDITOR
# ============================================================================

func generate_optimized_level_mesh() -> ArrayMesh:
	"""Single-surface mesh of all tiles. Used for in-editor preview."""
	var all_verts   := PackedVector3Array()
	var all_indices := PackedInt32Array()
	var all_normals := PackedVector3Array()
	var all_uvs     := PackedVector2Array()
	var all_tangents := PackedFloat32Array()
	var all_colors   := PackedColorArray()
	var v_offset := 0

	var by_type    := _group_by_type()
	var prog_total := tiles.size()
	var prog_done  := 0

	for tile_type in by_type:
		for pos in by_type[tile_type]:
			var tile_mesh := _tile_mesh_for_pos(pos, tile_type)
			var world_pos := tile_map.grid_to_world(pos)
			v_offset = append_mesh_surface_to_arrays(
				tile_mesh, 0, world_pos,
				all_verts, all_indices, all_normals, all_uvs,
				v_offset, all_tangents, all_colors
			)
			prog_done += 1
			if progress_callback.is_valid():
				progress_callback.call(prog_done, prog_total)

	var welded := _weld_surface_arrays(all_verts, all_normals, all_uvs, all_indices,
			all_tangents, all_colors)

	var mesh := ArrayMesh.new()
	if welded[0].size() > 0:
		var sa := []
		sa.resize(Mesh.ARRAY_MAX)
		sa[Mesh.ARRAY_VERTEX] = welded[0]
		sa[Mesh.ARRAY_NORMAL] = welded[1]
		sa[Mesh.ARRAY_TEX_UV] = welded[2]
		sa[Mesh.ARRAY_INDEX]  = welded[3]
		if (welded[5] as PackedColorArray).size() > 0:
			sa[Mesh.ARRAY_COLOR] = welded[5]
		commit_surface_with_tangents(mesh, sa)
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color.WHITE
		mesh.surface_set_material(0, mat)

	return mesh


func generate_optimized_level_mesh_multi_material() -> ArrayMesh:
	"""Multi-material mesh. Surfaces are grouped by (tile_type, palette_index)
	so tiles with the same type AND the same painted material share a surface.
	This lets us weld shared edges per group without a centroid-lookup split pass.

	Strategy per (tile_type, palette_index, mesh_surface_index) triple:
	  1. Collect all tiles in the group.
	  2. Build combined raw arrays.
	  3. Weld to close inter-tile gaps.
	  4. Emit one ArrayMesh surface with the resolved material.
	"""
	var mesh := ArrayMesh.new()

	# Build (tile_type, palette_index) -> [Vector3i] map.
	var groups: Dictionary[String, Dictionary] = {}  # key: "type:palette" -> { tile_type, palette_index, positions }
	for pos in tiles:
		var tt: int  = tiles[pos]
		var pal := int(tile_map.tile_materials.get(pos, -1))
		var key := "%d:%d" % [tt, pal]
		if key not in groups:
			groups[key] = { "tile_type": tt, "palette_index": pal, "positions": [] }
		groups[key]["positions"].append(pos)

	var prog_total := tiles.size()
	var prog_done  := 0

	for key in groups:
		var g          = groups[key]
		var tile_type: int     = g["tile_type"]
		var pal_index: int     = g["palette_index"]
		var positions: Array   = g["positions"]

		# Build per-position mesh cache.
		var mesh_cache: Dictionary[Vector3i, ArrayMesh] = {}
		for pos in positions:
			mesh_cache[pos] = _tile_mesh_for_pos(pos, tile_type)
			prog_done += 1
			if progress_callback.is_valid():
				progress_callback.call(prog_done, prog_total)

		# Always iterate all 3 surface roles (TOP=0, SIDES=1, BOTTOM=2).
		# Surfaces in the generated tile mesh are NOT at fixed indices —
		# MeshBuilder skips surfaces with no geometry, so SIDES may be at
		# index 0 when TOP is culled. We look up each surface by its role
		# name (set via surface_set_name) to get the correct geometry.
		for surf_role in range(3):  # 0=TOP, 1=SIDES, 2=BOTTOM
			var role_name: String = str(surf_role)
			var all_verts   := PackedVector3Array()
			var all_normals := PackedVector3Array()
			var all_uvs     := PackedVector2Array()
			var all_indices := PackedInt32Array()
			var v_offset    := 0

			for pos in positions:
				var tm: ArrayMesh = mesh_cache[pos]
				# Find the surface with this role name rather than assuming index.
				var found_idx: int = -1
				for si in range(tm.get_surface_count()):
					if tm.surface_get_name(si) == role_name:
						found_idx = si
						break
				if found_idx == -1:
					continue
				v_offset = append_mesh_surface_to_arrays(
					tm, found_idx, tile_map.grid_to_world(pos),
					all_verts, all_indices, all_normals, all_uvs, v_offset
				)

			if all_verts.size() == 0:
				continue

			var welded     := _weld_surface_arrays(all_verts, all_normals, all_uvs, all_indices)
			var clean_idx  := _remove_degenerate_triangles(welded[3])
			if clean_idx.size() == 0:
				continue

			var sa := []
			sa.resize(Mesh.ARRAY_MAX)
			sa[Mesh.ARRAY_VERTEX]  = welded[0]
			sa[Mesh.ARRAY_NORMAL]  = welded[1]
			sa[Mesh.ARRAY_TEX_UV]  = welded[2]
			sa[Mesh.ARRAY_INDEX]   = clean_idx
			commit_surface_with_tangents(mesh, sa)

			# Resolve material: palette > custom_materials > mesh default.
			var material := _resolve_material(tile_type, pal_index, surf_role)
			if material:
				mesh.surface_set_material(mesh.get_surface_count() - 1, material)

	return mesh


# ============================================================================
# PRIVATE — TILE MESH GENERATION
# ============================================================================

func _tile_mesh_for_pos(pos: Vector3i, tile_type: int) -> ArrayMesh:
	var neighbors: Dictionary = tile_map.get_neighbors(pos)
	var cull_top: bool = pos in _top_plane_cull
	if tile_type in custom_meshes or tile_type == MeshGenerator.TILE_TYPE_STAIRS:
		var rotation: float = tile_map.tile_rotations.get(pos, 0.0)
		return mesh_generator.generate_custom_tile_mesh(
				pos, tile_type, neighbors, rotation, false, 4, cull_top)
	else:
		return mesh_generator.generate_tile_mesh(tile_type, neighbors, cull_top)


func _group_by_type() -> Dictionary[int, Array]:
	var result: Dictionary[int, Array] = {}
	for pos in tiles:
		var tt: int = tiles[pos]
		if tt not in result:
			result[tt] = []
		result[tt].append(pos)
	return result


# ============================================================================
# PRIVATE — MATERIAL RESOLUTION
# ============================================================================

func _resolve_material(tile_type: int, palette_index: int, surf_idx: int) -> Material:
	var surface_suffix: String = ["_top", "_sides", "_bottom"][surf_idx] if surf_idx < 3 else ("_surf%d" % surf_idx)

	# 1. Palette material.
	if palette_index >= 0 and tile_map and tile_map.material_palette_ref:
		var palette = tile_map.material_palette_ref
		if palette.has_method("get_material_for_surface"):
			var mat: Material = palette.get_material_for_surface(palette_index, surf_idx)
			if mat:
				return mat
		elif palette.has_method("get_material_at_index"):
			var mat: Material = palette.get_material_at_index(palette_index)
			if mat:
				return mat

	# 2. Custom material registered on the tile type.
	if tile_type in custom_materials:
		var mats: Array = custom_materials[tile_type]
		if surf_idx < mats.size() and mats[surf_idx]:
			var mat: Material = mats[surf_idx]
			if mat.resource_name == "":
				mat.resource_name = "TileType%d%s" % [tile_type, surface_suffix]
			return mat

	# 3. Material baked into the template mesh.
	if tile_type in custom_meshes:
		var template: ArrayMesh = custom_meshes[tile_type]
		if surf_idx < template.get_surface_count():
			var mat := template.surface_get_material(surf_idx)
			if mat:
				if mat.resource_name == "":
					mat.resource_name = "TileType%d%s" % [tile_type, surface_suffix]
				return mat

	# 4. Fallback via TileMap3D helper.
	var fallback := tile_map.get_custom_material(tile_type, surf_idx)
	if fallback and fallback.resource_name == "":
		fallback.resource_name = "TileType%d%s" % [tile_type, surface_suffix]
	return fallback


# ============================================================================
# SHARED HELPERS  (also called by GlbExporter)
# ============================================================================

func commit_surface_with_tangents(target_mesh: ArrayMesh, sa: Array) -> void:
	"""Add a surface via SurfaceTool so tangents are auto-generated.
	sa must have VERTEX / NORMAL / TEX_UV / INDEX populated."""
	var tmp := ArrayMesh.new()
	tmp.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, sa)
	var st := SurfaceTool.new()
	st.create_from(tmp, 0)
	st.generate_tangents()
	target_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, st.commit_to_arrays())


func append_mesh_surface_to_arrays(
		mesh: ArrayMesh, surface_idx: int, world_pos: Vector3,
		verts: PackedVector3Array, indices: PackedInt32Array,
		normals: PackedVector3Array, uvs: PackedVector2Array,
		vertex_offset: int,
		tangents: PackedFloat32Array = PackedFloat32Array(),
		colors: PackedColorArray = PackedColorArray()) -> int:
	"""Append surface_idx of mesh (translated by world_pos) into the combined arrays.
	Returns the new vertex offset."""
	if surface_idx >= mesh.get_surface_count():
		return vertex_offset

	var arrays      := mesh.surface_get_arrays(surface_idx)
	var m_verts     := arrays[Mesh.ARRAY_VERTEX]   as PackedVector3Array
	var m_indices   := arrays[Mesh.ARRAY_INDEX]    as PackedInt32Array
	var m_normals   := arrays[Mesh.ARRAY_NORMAL]   as PackedVector3Array
	var m_uvs:      PackedVector2Array  = arrays[Mesh.ARRAY_TEX_UV]  if arrays[Mesh.ARRAY_TEX_UV]  else PackedVector2Array()
	var m_tangents: PackedFloat32Array  = arrays[Mesh.ARRAY_TANGENT] if arrays[Mesh.ARRAY_TANGENT] else PackedFloat32Array()
	var m_colors:   PackedColorArray    = arrays[Mesh.ARRAY_COLOR]   if arrays[Mesh.ARRAY_COLOR]   else PackedColorArray()

	for v in m_verts:
		verts.append(v + world_pos)
	for idx in m_indices:
		indices.append(idx + vertex_offset)
	for n in m_normals:
		normals.append(n)

	if m_uvs.size() == m_verts.size():
		for uv in m_uvs:
			uvs.append(uv)
	else:
		for _i in range(m_verts.size()):
			uvs.append(Vector2.ZERO)

	for t in m_tangents:
		tangents.append(t)
	if m_colors.size() == m_verts.size():
		for c in m_colors:
			colors.append(c)

	return vertex_offset + m_verts.size()


func _weld_surface_arrays(
		in_verts:   PackedVector3Array,
		in_normals: PackedVector3Array,
		in_uvs:     PackedVector2Array,
		in_indices: PackedInt32Array,
		in_tangents: PackedFloat32Array = PackedFloat32Array(),
		in_colors:   PackedColorArray   = PackedColorArray()
) -> Array:
	"""Merge duplicate positional vertices within WELD_EPSILON.
	Returns [verts, normals, uvs, indices, tangents, colors]."""
	var out_verts    := PackedVector3Array()
	var out_normals  := PackedVector3Array()
	var out_uvs      := PackedVector2Array()
	var out_tangents := PackedFloat32Array()
	var out_colors   := PackedColorArray()

	var has_tangents := in_tangents.size() == in_verts.size() * 4
	var has_colors   := in_colors.size()   == in_verts.size()

	# Map snap_key -> canonical output index (also used as per-old-vertex remap).
	var key_to_idx: Dictionary[String, int] = {}
	# Per-old-vertex remap: old_vertex_index -> canonical output index.
	var vertex_remap := PackedInt32Array()
	vertex_remap.resize(in_verts.size())

	for old_idx in range(in_verts.size()):
		var key := _snap_key(in_verts[old_idx])
		if key in key_to_idx:
			vertex_remap[old_idx] = key_to_idx[key]
		else:
			var new_idx := out_verts.size()
			key_to_idx[key]     = new_idx
			vertex_remap[old_idx] = new_idx
			out_verts.append(in_verts[old_idx])
			out_normals.append(in_normals[old_idx] if old_idx < in_normals.size() else Vector3.UP)
			out_uvs.append(in_uvs[old_idx] if old_idx < in_uvs.size() else Vector2.ZERO)
			if has_tangents:
				var t := old_idx * 4
				out_tangents.append(in_tangents[t])
				out_tangents.append(in_tangents[t + 1])
				out_tangents.append(in_tangents[t + 2])
				out_tangents.append(in_tangents[t + 3])
			if has_colors:
				out_colors.append(in_colors[old_idx])

	var out_indices := PackedInt32Array()
	out_indices.resize(in_indices.size())
	for i in range(in_indices.size()):
		out_indices[i] = vertex_remap[in_indices[i]]

	return [out_verts, out_normals, out_uvs, out_indices, out_tangents, out_colors]


func _remove_degenerate_triangles(indices: PackedInt32Array) -> PackedInt32Array:
	"""Remove triangles where two or more vertex indices are identical (zero-area)."""
	var clean := PackedInt32Array()
	for i in range(0, indices.size(), 3):
		var i0 := indices[i];  var i1 := indices[i+1];  var i2 := indices[i+2]
		if i0 != i1 and i1 != i2 and i0 != i2:
			clean.append(i0);  clean.append(i1);  clean.append(i2)
	return clean


func _snap_key(v: Vector3) -> String:
	return "%d,%d,%d" % [roundi(v.x / WELD_EPSILON), roundi(v.y / WELD_EPSILON), roundi(v.z / WELD_EPSILON)]
