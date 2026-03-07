#@tool
extends EditorScript

# Run once from File > Run to generate tile icons at res://Icons/

const OUTPUT_DIR  = "res://Icons/"
const ICON_SIZE   = 256
const GRID_SIZE   = 1.0

const CAM_POSITION = Vector3(1.8, 2.0, 2.2)
const CAM_TARGET   = Vector3(0.5, 0.3, 0.5)

# Surface order matches the mesh export: Top, Sides, Bottom
const TEX_TOP    = "res://Images/Grass.png"
const TEX_SIDE   = "res://Images/dirt.png"
const TEX_BOTTOM = "res://Images/dirt.png"


func _run() -> void:
	var dir_path: String = ProjectSettings.globalize_path(OUTPUT_DIR)
	DirAccess.make_dir_recursive_absolute(dir_path)
	print("Output directory: ", dir_path)

	_render_and_save(_load_cube_mesh(),     dir_path + "tile_cube.png")
	_render_and_save(_generate_stair_mesh(), dir_path + "tile_stairs.png")

	print("✓ Done — rescan FileSystem to see the files")


# ============================================================================
# MESH SOURCES
# ============================================================================

func _load_cube_mesh() -> ArrayMesh:
	var mesh: ArrayMesh = load("res://cubes/cube_bulge.obj")
	if mesh == null:
		push_error("Could not load cube_bulge.obj")
	return mesh


func _generate_stair_mesh() -> ArrayMesh:
	return ProceduralStairsGenerator.generate_stairs_mesh(4, GRID_SIZE, 0.0)


# ============================================================================
# MATERIAL BUILDER
# ============================================================================

func _make_material(texture_path: String) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	var tex: Texture2D = load(texture_path)
	if tex:
		mat.albedo_texture = tex
	return mat


# ============================================================================
# RENDER
# ============================================================================

func _render_and_save(mesh: ArrayMesh, output_path: String) -> void:
	if mesh == null or mesh.get_surface_count() == 0:
		push_error("Invalid mesh for: " + output_path)
		return

	print("  Rendering: ", output_path.get_file())

	var root := Node3D.new()

	var mi := MeshInstance3D.new()
	mi.mesh = mesh

	# Apply materials per surface based on name
	for i in range(mesh.get_surface_count()):
		var surf_name: String = mesh.surface_get_name(i).to_lower()
		var mat: StandardMaterial3D
		if "top" in surf_name:
			mat = _make_material(TEX_TOP)
		elif "bottom" in surf_name:
			mat = _make_material(TEX_BOTTOM)
		else:
			mat = _make_material(TEX_SIDE)
		mi.set_surface_override_material(i, mat)

	root.add_child(mi)

	var light := DirectionalLight3D.new()
	light.transform = Transform3D(Basis.from_euler(Vector3(-0.8, 0.6, 0.0)), Vector3.ZERO)
	light.light_energy = 1.2
	root.add_child(light)

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.12, 0.12, 0.12)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.4, 0.4, 0.4)
	env.ambient_light_energy = 1.0
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	root.add_child(world_env)

	var camera := Camera3D.new()
	var cam_forward: Vector3 = (CAM_TARGET - CAM_POSITION).normalized()
	var cam_right: Vector3   = cam_forward.cross(Vector3.UP).normalized()
	var cam_up: Vector3      = cam_right.cross(cam_forward).normalized()
	camera.transform = Transform3D(Basis(cam_right, cam_up, -cam_forward), CAM_POSITION)
	camera.fov = 40.0
	root.add_child(camera)

	var viewport := SubViewport.new()
	viewport.size = Vector2i(ICON_SIZE, ICON_SIZE)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.transparent_bg = true
	viewport.add_child(root)

	EditorInterface.get_base_control().add_child(viewport)
	RenderingServer.force_draw(false)

	var image: Image = viewport.get_texture().get_image()
	if image == null or image.is_empty():
		push_error("Failed to capture image for: " + output_path)
	else:
		var err: Error = image.save_png(output_path)
		if err == OK:
			print("  ✓ Saved: ", output_path)
		else:
			push_error("save_png failed for " + output_path + " err=" + str(err))

	viewport.queue_free()
