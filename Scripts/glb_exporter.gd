class_name GlbExporter extends RefCounted

# ============================================================================
# GLB EXPORTER
# ============================================================================
# Owns all GLB export logic. Two public entry points:
#
#   build_export_mesh(snapshot)            → ArrayMesh   (worker-thread safe)
#   build_chunk_meshes(name, size, snap)   → Dictionary  (worker-thread safe)
#
#   save_single(mesh, filepath)            → bool        (main thread only)
#   save_chunks(chunk_data)                → void        (main thread only)
#
# The build_* functions do only pure data work — no scene API, no file I/O.
# The save_* functions must be called from the main thread.
# ============================================================================

# ============================================================================
# DEPENDENCIES
# ============================================================================
var tile_map: TileMap3D
var mesh_optimizer: MeshOptimizer

# Optional progress callback. Signature: func(done: int, total: int).
# Called via call_deferred so it is safe to touch UI from the worker thread.
var progress_callback: Callable

# ============================================================================
# CONSTANTS
# ============================================================================
const TOP_Y_OFFSET:    float = 0.0001
const TOP_CORNER_INSET: float = 0.070246  # must match TileMap3D._TOP_CORNER_INSET
const CHUNK_SIZE: Vector3i = Vector3i(32, 32, 32)

# ============================================================================
# SETUP
# ============================================================================

func setup(tilemap_ref: TileMap3D, optimizer_ref: MeshOptimizer) -> void:
	tile_map      = tilemap_ref
	mesh_optimizer = optimizer_ref


# ============================================================================
# PUBLIC — WORKER-THREAD SAFE
# ============================================================================

func build_export_mesh(top_plane_snapshot: Array) -> ArrayMesh:
	"""Build the combined single-mesh export. Worker-thread safe.
	top_plane_snapshot must be captured on the main thread before calling."""
	mesh_optimizer.progress_callback = progress_callback
	var top_positions := _snapshot_to_positions(top_plane_snapshot)
	mesh_optimizer.set_top_plane_cull_positions(top_positions)

	var mesh := mesh_optimizer.generate_optimized_level_mesh_multi_material()
	mesh_optimizer.progress_callback = Callable()
	_bake_top_plane(mesh, top_plane_snapshot)
	return mesh


func build_chunk_meshes(save_name: String, top_plane_snapshot: Array,
		chunk_size: Vector3i = CHUNK_SIZE) -> Dictionary:
	"""Build all chunk meshes. Worker-thread safe.
	Returns a Dictionary ready for save_chunks(), or empty on failure."""
	var tiles: Dictionary[Vector3i, int] = tile_map.tiles
	if tiles.is_empty():
		push_error("GlbExporter: no tiles to export")
		return {}

	var top_positions := _snapshot_to_positions(top_plane_snapshot)

	var export_dir := "user://exports/exported_level_" + save_name + "/"
	print("\n=== GLB CHUNKED EXPORT — BUILDING MESHES ===")
	print("Save name: ", save_name, "  Chunk size: ", chunk_size)
	print("Export directory: ", export_dir)
	print("Total tiles: ", tiles.size())

	var bounds      := _calculate_bounds(tiles)
	var chunk_defs  := _divide_into_chunks(bounds, chunk_size)
	print("Total chunks defined: ", chunk_defs.size())

	var total_tiles  := tiles.size()
	var tiles_done   := 0
	var built_chunks: Array = []

	for chunk in chunk_defs:
		var chunk_tiles := _tiles_in_chunk(tiles, chunk)
		if chunk_tiles.is_empty():
			continue

		var coord: Vector3i = chunk["coord"]
		var chunk_name      := "chunk_%d_%d_%d" % [coord.x, coord.y, coord.z]
		print("  Building [%d,%d,%d]: %d tiles" % [coord.x, coord.y, coord.z, chunk_tiles.size()])

		# Pass progress callback scaled to overall tile count so the bar
		# advances continuously across all chunks.
		var chunk_offset := tiles_done
		var chunk_total  := total_tiles
		mesh_optimizer.progress_callback = func(done: int, _total: int) -> void:
			if progress_callback.is_valid():
				progress_callback.call(chunk_offset + done, chunk_total)

		var chunk_mesh := _build_chunk_mesh(chunk_tiles, tiles,
				top_positions, top_plane_snapshot)
		mesh_optimizer.progress_callback = Callable()

		tiles_done += chunk_tiles.size()

		built_chunks.append({
			"name":     chunk_name,
			"filepath": export_dir + chunk_name + ".glb",
			"mesh":     chunk_mesh,
		})

	var metadata := {
		"save_name":    save_name,
		"chunk_size":   { "x": chunk_size.x, "y": chunk_size.y, "z": chunk_size.z },
		"bounds_min":   { "x": bounds["min"].x, "y": bounds["min"].y, "z": bounds["min"].z },
		"bounds_max":   { "x": bounds["max"].x, "y": bounds["max"].y, "z": bounds["max"].z },
		"total_tiles":  tiles.size(),
		"total_chunks": built_chunks.size(),
		"export_date":  Time.get_datetime_string_from_system(),
	}

	print("=== CHUNK MESH BUILD COMPLETE ===\n")
	return {
		"export_dir": export_dir,
		"chunks":     built_chunks,
		"metadata":   metadata,
	}


# ============================================================================
# PUBLIC — MAIN THREAD ONLY
# ============================================================================

func save_single(mesh: ArrayMesh, filepath: String) -> bool:
	"""Write a single GLB file. Main thread only."""
	if not filepath.ends_with(".glb") and not filepath.ends_with(".gltf"):
		filepath += ".glb"
	_snap_mesh_vertices(mesh)
	return _write_glb(mesh, "ExportedLevel", filepath)


func save_chunks(chunk_data: Dictionary) -> void:
	"""Write all chunk GLB files and the metadata manifest. Main thread only."""
	if chunk_data.is_empty():
		push_error("GlbExporter.save_chunks: empty chunk data")
		return

	var export_dir: String = chunk_data["export_dir"]
	DirAccess.make_dir_recursive_absolute("user://exports/")
	DirAccess.make_dir_recursive_absolute(export_dir)

	print("\n=== GLB CHUNKED EXPORT — SAVING FILES ===")

	for chunk in chunk_data["chunks"]:
		var chunk_mesh: ArrayMesh = chunk["mesh"]
		_snap_mesh_vertices(chunk_mesh)
		var ok := _write_glb(chunk_mesh, chunk["name"], chunk["filepath"])
		if ok:
			print("  ✓ ", chunk["filepath"])

	var manifest_path := export_dir + "metadata.json"
	var f := FileAccess.open(manifest_path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(chunk_data["metadata"], "\t"))
		f.close()
		print("✓ Manifest saved: ", manifest_path)
	else:
		push_error("GlbExporter: failed to write manifest at " + manifest_path)

	print("=== CHUNKED EXPORT COMPLETE ===\n")


# ============================================================================
# PRIVATE — MESH BUILDING
# ============================================================================

func _build_chunk_mesh(chunk_tiles: Dictionary[Vector3i, int], full_tiles: Dictionary[Vector3i, int],
		top_positions: Dictionary[Vector3i, bool], top_plane_snapshot: Array) -> ArrayMesh:
	# Temporarily swap the tile references on the optimizer so
	# generate_optimized_level_mesh_multi_material emits only this chunk's
	# geometry while neighbour lookups still see the full tile set.
	var saved_opt_tiles: Dictionary[Vector3i, int] = mesh_optimizer.tiles
	var saved_map_tiles: Dictionary[Vector3i, int] = tile_map.tiles

	mesh_optimizer.tiles  = chunk_tiles
	tile_map.tiles        = full_tiles
	mesh_optimizer.set_top_plane_cull_positions(top_positions)

	var chunk_mesh := mesh_optimizer.generate_optimized_level_mesh_multi_material()

	# Bake top-plane while chunk_tiles is still the emit set so we only bake
	# quads that belong to this chunk. tile_map.tiles remains the full set for
	# correct neighbour-inset calculations inside _bake_top_plane.
	_bake_top_plane_for_tiles(chunk_mesh, chunk_tiles, top_plane_snapshot)

	mesh_optimizer.tiles = saved_opt_tiles
	tile_map.tiles       = saved_map_tiles
	return chunk_mesh


# ============================================================================
# PRIVATE — TOP-PLANE BAKING
# ============================================================================

func _bake_top_plane(mesh: ArrayMesh, top_plane_snapshot: Array) -> void:
	"""Bake top-plane overlay quads for all tiles into mesh."""
	_bake_top_plane_for_tiles(mesh, tile_map.tiles, top_plane_snapshot)


func _bake_top_plane_for_tiles(mesh: ArrayMesh, emit_tiles: Dictionary[Vector3i, int],
		top_plane_snapshot: Array) -> void:
	"""Bake top-plane overlay quads for only the tiles in emit_tiles.
	tile_map.tiles is used for neighbour lookups so chunk-boundary insets are correct."""
	if emit_tiles.is_empty():
		return

	var pos_to_mat: Dictionary[Vector3i, Material] = {}
	for entry in top_plane_snapshot:
		if entry.has("grid_pos"):
			pos_to_mat[entry["grid_pos"]] = entry.get("material", null)

	var s: float = tile_map.grid_size
	var groups: Dictionary[String, Dictionary] = {}  # mat_key -> surface data

	for pos in emit_tiles:
		# Stairs have no flat top — skip.
		if emit_tiles[pos] == MeshGenerator.TILE_TYPE_STAIRS:
			continue
		# Tile covered from above — skip.
		if Vector3i(pos.x, pos.y + 1, pos.z) in tile_map.tiles:
			continue

		# Resolve material: snapshot > palette > custom.
		var mat: Material = pos_to_mat.get(pos, null)
		if mat == null and tile_map.material_palette_ref:
			var pal_idx := int(tile_map.tile_materials.get(pos, -1))
			if pal_idx >= 0:
				mat = tile_map.material_palette_ref.get_material_for_surface(pal_idx, 0)
		if mat == null:
			mat = tile_map.get_custom_material(emit_tiles[pos], 0)

		# Per-corner inset — use tile_map.tiles (full set) for neighbour checks.
		var wp    := tile_map.grid_to_world(pos)
		var has_n: bool = Vector3i(pos.x,     pos.y, pos.z - 1) in tile_map.tiles
		var has_s: bool = Vector3i(pos.x,     pos.y, pos.z + 1) in tile_map.tiles
		var has_e: bool = Vector3i(pos.x + 1, pos.y, pos.z    ) in tile_map.tiles
		var has_w: bool = Vector3i(pos.x - 1, pos.y, pos.z    ) in tile_map.tiles
		var ci    := TOP_CORNER_INSET
		var qy    := wp.y + s + TOP_Y_OFFSET

		var x_nw := wp.x +     (0.0 if has_w else ci)
		var z_nw := wp.z +     (0.0 if has_n else ci)
		var x_ne := wp.x + s - (0.0 if has_e else ci)
		var z_ne := wp.z +     (0.0 if has_n else ci)
		var x_se := wp.x + s - (0.0 if has_e else ci)
		var z_se := wp.z + s - (0.0 if has_s else ci)
		var x_sw := wp.x +     (0.0 if has_w else ci)
		var z_sw := wp.z + s - (0.0 if has_s else ci)

		var v0 := Vector3(x_nw, qy, z_nw)
		var v1 := Vector3(x_ne, qy, z_ne)
		var v2 := Vector3(x_se, qy, z_se)
		var v3 := Vector3(x_sw, qy, z_sw)

		var mat_key := str(mat.get_instance_id()) if mat else "null"
		if mat_key not in groups:
			groups[mat_key] = {
				"material": mat,
				"verts":    PackedVector3Array(),
				"normals":  PackedVector3Array(),
				"uvs":      PackedVector2Array(),
				"indices":  PackedInt32Array(),
				"voffset":  0,
			}
		var g  = groups[mat_key]
		var bi: int = g["voffset"]
		g["verts"].append_array([v0, v1, v2, v3])
		g["normals"].append_array([Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP])
		g["uvs"].append_array([
			Vector2((x_nw - wp.x) / s, (z_nw - wp.z) / s),
			Vector2((x_ne - wp.x) / s, (z_ne - wp.z) / s),
			Vector2((x_se - wp.x) / s, (z_se - wp.z) / s),
			Vector2((x_sw - wp.x) / s, (z_sw - wp.z) / s),
		])
		g["indices"].append_array([bi, bi+1, bi+2,  bi, bi+2, bi+3])
		g["voffset"] = bi + 4

	for mat_key in groups:
		var g = groups[mat_key]
		if g["verts"].size() == 0:
			continue
		var sa := []
		sa.resize(Mesh.ARRAY_MAX)
		sa[Mesh.ARRAY_VERTEX]  = g["verts"]
		sa[Mesh.ARRAY_NORMAL]  = g["normals"]
		sa[Mesh.ARRAY_TEX_UV]  = g["uvs"]
		sa[Mesh.ARRAY_INDEX]   = g["indices"]
		mesh_optimizer.commit_surface_with_tangents(mesh, sa)
		if g["material"]:
			mesh.surface_set_material(mesh.get_surface_count() - 1, g["material"])


# ============================================================================
# PRIVATE — VERTEX SNAPPING
# ============================================================================

func _snap_mesh_vertices(mesh: ArrayMesh) -> void:
	"""Snap all vertex positions to SNAP_PRECISION before GLB serialization.
	Eliminates microgaps caused by float32 rounding in the GLTF writer.
	Safe for triplanar materials since UVs are computed in the shader from
	world position — no baked UV data is affected."""
	const SNAP: float = 0.0001
	var surf_count := mesh.get_surface_count()

	# Collect all surfaces and their materials before touching the mesh.
	var surfaces: Array = []
	for surf_idx in range(surf_count):
		var arrays := mesh.surface_get_arrays(surf_idx)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		for i in range(verts.size()):
			verts[i] = Vector3(
				snapped(verts[i].x, SNAP),
				snapped(verts[i].y, SNAP),
				snapped(verts[i].z, SNAP)
			)
		arrays[Mesh.ARRAY_VERTEX] = verts
		surfaces.append({
			"arrays":   arrays,
			"material": mesh.surface_get_material(surf_idx),
		})

	# Clear and rebuild — surface_remove shifts indices so we can't remove
	# in a forward loop. Clearing and re-adding is the safe approach.
	mesh.clear_surfaces()
	for s in surfaces:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, s["arrays"])
		if s["material"]:
			mesh.surface_set_material(mesh.get_surface_count() - 1, s["material"])


# ============================================================================
# PRIVATE — GLB FILE I/O  (main thread only)
# ============================================================================

func _write_glb(mesh: ArrayMesh, instance_name: String, filepath: String) -> bool:
	"""Wrap mesh in a minimal scene and write it as a GLB. Main thread only."""
	var mi := MeshInstance3D.new()
	mi.name = instance_name
	mi.mesh = mesh

	var root := Node3D.new()
	root.name = "Scene"
	root.add_child(mi)
	mi.owner = root

	var doc   := GLTFDocument.new()
	var state := GLTFState.new()
	var err   := doc.append_from_scene(root, state)
	root.free()

	if err != OK:
		push_error("GlbExporter: append_from_scene failed (error %d) for %s" % [err, filepath])
		return false

	var dir := filepath.get_base_dir()
	if dir != "" and dir != "res://" and dir != "user://":
		DirAccess.make_dir_recursive_absolute(dir)

	var write_err := doc.write_to_filesystem(state, filepath)
	if write_err != OK:
		push_error("GlbExporter: write_to_filesystem failed (error %d) for %s" % [write_err, filepath])
		return false

	return true


# ============================================================================
# PRIVATE — CHUNK SPATIAL HELPERS
# ============================================================================

func _calculate_bounds(tiles: Dictionary[Vector3i, int]) -> Dictionary:
	var mn := Vector3i( 999999,  999999,  999999)
	var mx := Vector3i(-999999, -999999, -999999)
	for pos in tiles:
		mn.x = mini(mn.x, pos.x);  mx.x = maxi(mx.x, pos.x)
		mn.y = mini(mn.y, pos.y);  mx.y = maxi(mx.y, pos.y)
		mn.z = mini(mn.z, pos.z);  mx.z = maxi(mx.z, pos.z)
	return { "min": mn, "max": mx }


func _divide_into_chunks(bounds: Dictionary, chunk_size: Vector3i) -> Array:
	var mn: Vector3i = bounds["min"]
	var mx: Vector3i = bounds["max"]
	var min_chunk := Vector3i(
		floori(float(mn.x) / chunk_size.x),
		floori(float(mn.y) / chunk_size.y),
		floori(float(mn.z) / chunk_size.z)
	)
	var max_chunk := Vector3i(
		floori(float(mx.x) / chunk_size.x),
		floori(float(mx.y) / chunk_size.y),
		floori(float(mx.z) / chunk_size.z)
	)
	var chunks: Array = []
	for cx in range(min_chunk.x, max_chunk.x + 1):
		for cy in range(min_chunk.y, max_chunk.y + 1):
			for cz in range(min_chunk.z, max_chunk.z + 1):
				chunks.append({
					"coord": Vector3i(cx, cy, cz),
					"min":   Vector3i(cx * chunk_size.x,       cy * chunk_size.y,       cz * chunk_size.z),
					"max":   Vector3i((cx+1)*chunk_size.x - 1, (cy+1)*chunk_size.y - 1, (cz+1)*chunk_size.z - 1),
				})
	return chunks


func _tiles_in_chunk(tiles: Dictionary[Vector3i, int], chunk: Dictionary) -> Dictionary[Vector3i, int]:
	var result: Dictionary[Vector3i, int] = {}
	var cmin: Vector3i = chunk["min"]
	var cmax: Vector3i = chunk["max"]
	for pos in tiles:
		if pos.x >= cmin.x and pos.x <= cmax.x and \
		   pos.y >= cmin.y and pos.y <= cmax.y and \
		   pos.z >= cmin.z and pos.z <= cmax.z:
			result[pos] = tiles[pos]
	return result


# ============================================================================
# PRIVATE — SNAPSHOT HELPERS
# ============================================================================

func _snapshot_to_positions(snapshot: Array) -> Dictionary[Vector3i, bool]:
	"""Convert a top-plane snapshot to a set of grid positions (Vector3i -> true).
	Used to tell the optimizer which tile top faces to cull."""
	var result: Dictionary[Vector3i, bool] = {}
	for entry in snapshot:
		if entry.has("grid_pos"):
			result[entry["grid_pos"]] = true
	return result
