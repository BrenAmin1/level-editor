@tool
extends EditorScript

# Run this once from the Godot editor via File > Run to generate tile icons.
# Icons are saved to res://Images/ as PNG files.

const OUTPUT_DIR = "res://Icons/"
const ICON_SIZE = 64
const GRID_SIZE = 1.0

# Camera position for 3/4 perspective view
const CAM_POSITION = Vector3(1.8, 2.0, 2.2)
const CAM_TARGET = Vector3(0.5, 0.3, 0.5)


func _run():
	# Ensure output directory exists
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_DIR))

	_generate_icon_for_mesh(
		_load_cube_mesh(),
		OUTPUT_DIR + "tile_cube.png"
	)

	_generate_icon_for_mesh(
		_generate_stair_mesh(),
		OUTPUT_DIR + "tile_stairs.png"
	)

	print("✓ Tile icons generated in ", OUTPUT_DIR)


# ============================================================================
# MESH SOURCES
# ============================================================================

func _load_cube_mesh() -> ArrayMesh:
	var mesh = load("res://cubes/cube_bulge.obj")
	if mesh == null:
		push_error("Could not load cube_bulge.obj")
		return ArrayMesh.new()
	return mesh


func _generate_stair_mesh() -> ArrayMesh:
	return ProceduralStairsGenerator.generate_stairs_mesh(4, GRID_SIZE, 0.0)


# ============================================================================
# ICON RENDERING
# ============================================================================

func _generate_icon_for_mesh(mesh: ArrayMesh, output_path: String):
	if mesh == null or mesh.get_surface_count() == 0:
		push_error("Invalid mesh for: " + output_path)
		return

	# Build scene tree
	var root = Node3D.new()

	# Mesh instance
	var mi = MeshInstance3D.new()
	mi.mesh = mesh
	root.add_child(mi)

	# Light
	var light = DirectionalLight3D.new()
	light.transform = Transform3D(Basis.from_euler(Vector3(-0.8, 0.6, 0.0)), Vector3.ZERO)
	light.light_energy = 1.2
	root.add_child(light)

	# Ambient via environment
	var env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.15, 0.15, 0.15)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.4, 0.4, 0.4)
	env.ambient_light_energy = 1.0

	var world_env = WorldEnvironment.new()
	world_env.environment = env
	root.add_child(world_env)

	# Camera — compute transform manually so it doesn't need to be in the tree
	var camera = Camera3D.new()
	var cam_forward = (CAM_TARGET - CAM_POSITION).normalized()
	var cam_right = cam_forward.cross(Vector3.UP).normalized()
	var cam_up = cam_right.cross(cam_forward).normalized()
	camera.transform = Transform3D(
		Basis(cam_right, cam_up, -cam_forward),
		CAM_POSITION
	)
	camera.fov = 40.0
	root.add_child(camera)

	# SubViewport
	var viewport = SubViewport.new()
	viewport.size = Vector2i(ICON_SIZE, ICON_SIZE)
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	viewport.transparent_bg = true
	viewport.add_child(root)

	# Add to scene tree so it actually renders
	EditorInterface.get_base_control().add_child(viewport)

	# Wait two frames for the render to complete
	await EditorInterface.get_base_control().get_tree().process_frame
	await EditorInterface.get_base_control().get_tree().process_frame

	# Grab and save the image
	var image = viewport.get_texture().get_image()
	if image == null:
		push_error("Failed to capture viewport for: " + output_path)
	else:
		var err = image.save_png(ProjectSettings.globalize_path(output_path))
		if err == OK:
			print("  Saved: ", output_path)
		else:
			push_error("Failed to save: " + output_path + " (error " + str(err) + ")")

	# Cleanup
	viewport.queue_free()
