class_name BlockMenu extends Control

signal tile_type_selected(type: int)
signal ui_hover_changed(is_hovered: bool)

@onready var panel: Panel = $Panel
@onready var toggle_button: Button = $Panel/ToggleButton
@onready var grid_container: GridContainer = $Panel/VBoxContainer/GridContainer

var is_open: bool = false
var is_mouse_inside: bool = false
var tween: Tween
var panel_width: float = 300.0
var button_width: float = 30.0

# Maps tile_type int -> MeshInstance3D so we can swap materials later
var _preview_mesh_instances: Dictionary = {}  # int -> MeshInstance3D

# Camera constants — same 3/4 view as generate_icons.gd
const CAM_POSITION = Vector3(1.8, 2.0, 2.2)
const CAM_TARGET   = Vector3(0.5, 0.3, 0.5)
const PREVIEW_SIZE = Vector2i(80, 80)

# ============================================================================
# INITIALIZATION
# ============================================================================

func _ready() -> void:
	panel.position.x = panel_width - button_width
	_update_toggle_button()
	# Toggle button can sit outside the panel's tracked rect when closed.
	# Use button_down/up to block placement before the click is processed,
	# and mouse_entered/exited for hover state while the cursor lingers.
	toggle_button.button_down.connect(func() -> void: ui_hover_changed.emit(true))
	toggle_button.button_up.connect(func() -> void: ui_hover_changed.emit(false))
	toggle_button.mouse_entered.connect(func() -> void: ui_hover_changed.emit(true))
	toggle_button.mouse_exited.connect(func() -> void: ui_hover_changed.emit(false))


func _process(_delta):
	var mouse_over = _is_mouse_over_ui()
	if mouse_over != is_mouse_inside:
		is_mouse_inside = mouse_over
		ui_hover_changed.emit(is_mouse_inside)


func _is_mouse_over_ui() -> bool:
	if not visible:
		return false
	var rect = get_global_rect()
	var mouse_pos = get_global_mouse_position()
	return rect.has_point(mouse_pos)


# Call this from level_editor._ready() once tilemap meshes are loaded.
# tile_defs is an Array of Dictionaries, each with:
#   "type":      int          — tile type constant
#   "label":     String       — display name
#   "mesh_path": String       — res:// path to OBJ (will be loaded + reclassified)
#                               pass "" if supplying a pre-built mesh directly
#   "mesh":      ArrayMesh    — used when mesh_path is "" (e.g. procedural stairs)
func setup(tile_defs: Array) -> void:
	for child in grid_container.get_children():
		child.queue_free()
	_preview_mesh_instances.clear()

	for tile_def in tile_defs:
		var mesh: ArrayMesh
		if tile_def.get("mesh_path", "") != "":
			# Load OBJ and reclassify triangles by normal, same as material_maker_popup
			var raw = load(tile_def["mesh_path"]) as ArrayMesh
			if raw:
				mesh = _reclassify_mesh_by_normals(raw)
			else:
				push_error("BlockMenu: failed to load mesh at " + tile_def["mesh_path"])
		else:
			# Pre-built mesh supplied directly (e.g. procedural stairs)
			mesh = tile_def.get("mesh")

		_create_tile_button(tile_def, mesh)


# ============================================================================
# MESH RECLASSIFICATION
# Mirrors _reclassify_mesh_by_normals in material_maker_popup.gd:
# splits a single-surface OBJ into TOP / SIDES / BOTTOM by average triangle normal.
# ============================================================================

func _reclassify_mesh_by_normals(source_mesh: ArrayMesh) -> ArrayMesh:
	var top_verts    := PackedVector3Array(); var top_normals    := PackedVector3Array()
	var top_uvs      := PackedVector2Array(); var top_indices    := PackedInt32Array()
	var sides_verts  := PackedVector3Array(); var sides_normals  := PackedVector3Array()
	var sides_uvs    := PackedVector2Array(); var sides_indices  := PackedInt32Array()
	var bottom_verts := PackedVector3Array(); var bottom_normals := PackedVector3Array()
	var bottom_uvs   := PackedVector2Array(); var bottom_indices := PackedInt32Array()

	for surf_idx in range(source_mesh.get_surface_count()):
		var arrays  = source_mesh.surface_get_arrays(surf_idx)
		var verts   = arrays[Mesh.ARRAY_VERTEX]
		var normals = arrays[Mesh.ARRAY_NORMAL]
		var uvs     = arrays[Mesh.ARRAY_TEX_UV]
		var indices = arrays[Mesh.ARRAY_INDEX]

		for i in range(0, indices.size(), 3):
			var i0 = indices[i]; var i1 = indices[i + 1]; var i2 = indices[i + 2]

			var uv0 = uvs[i0] if uvs and i0 < uvs.size() else Vector2.ZERO
			var uv1 = uvs[i1] if uvs and i1 < uvs.size() else Vector2.ZERO
			var uv2 = uvs[i2] if uvs and i2 < uvs.size() else Vector2.ZERO

			var avg_normal = (normals[i0] + normals[i1] + normals[i2]).normalized()

			if avg_normal.y > 0.8:
				var s = top_verts.size()
				top_verts.append_array([verts[i0], verts[i1], verts[i2]])
				top_normals.append_array([normals[i0], normals[i1], normals[i2]])
				top_uvs.append_array([uv0, uv1, uv2])
				top_indices.append_array([s, s + 1, s + 2])
			elif avg_normal.y < -0.8:
				var s = bottom_verts.size()
				bottom_verts.append_array([verts[i0], verts[i1], verts[i2]])
				bottom_normals.append_array([normals[i0], normals[i1], normals[i2]])
				bottom_uvs.append_array([uv0, uv1, uv2])
				bottom_indices.append_array([s, s + 1, s + 2])
			else:
				var s = sides_verts.size()
				sides_verts.append_array([verts[i0], verts[i1], verts[i2]])
				sides_normals.append_array([normals[i0], normals[i1], normals[i2]])
				sides_uvs.append_array([uv0, uv1, uv2])
				sides_indices.append_array([s, s + 1, s + 2])

	var new_mesh := ArrayMesh.new()
	for group in [
		[top_verts,    top_normals,    top_uvs,    top_indices],
		[sides_verts,  sides_normals,  sides_uvs,  sides_indices],
		[bottom_verts, bottom_normals, bottom_uvs, bottom_indices],
	]:
		if group[0].size() == 0:
			continue
		var sa = []
		sa.resize(Mesh.ARRAY_MAX)
		sa[Mesh.ARRAY_VERTEX] = group[0]
		sa[Mesh.ARRAY_NORMAL] = group[1]
		sa[Mesh.ARRAY_TEX_UV] = group[2]
		sa[Mesh.ARRAY_INDEX]  = group[3]
		new_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, sa)

	return new_mesh


# ============================================================================
# BUTTON CREATION
# ============================================================================

func _create_tile_button(tile_def: Dictionary, mesh: ArrayMesh) -> void:
	var tile_type: int = tile_def["type"]
	var label_text: String = tile_def["label"]
	var button = Button.new()
	button.custom_minimum_size = Vector2(90, 100)
	button.toggle_mode = true
	button.clip_contents = true
	grid_container.add_child(button)

	var vbox = VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(vbox)

	var vp_container = SubViewportContainer.new()
	vp_container.custom_minimum_size = Vector2(80, 68)
	vp_container.stretch = true
	vp_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(vp_container)

	var viewport = SubViewport.new()
	viewport.size = Vector2i(80, 68)
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	viewport.transparent_bg = true
	viewport.own_world_3d = true  # Isolates from main scene world and other viewports
	vp_container.add_child(viewport)

	var scene_root = Node3D.new()
	viewport.add_child(scene_root)

	var mesh_instance = MeshInstance3D.new()
	if mesh:
		mesh_instance.mesh = mesh
	var preview_rot: float = tile_def.get("preview_rotation_y", 0.0)
	if preview_rot != 0.0:
		# Rotate around the tile's centre (0.5, 0, 0.5) rather than its corner,
		# matching _apply_rotation_center_offset in tile_manager.gd.
		var center = Vector3(0.5, 0.0, 0.5)
		mesh_instance.position = center
		mesh_instance.rotation_degrees.y = preview_rot
		mesh_instance.position -= mesh_instance.basis * center
	scene_root.add_child(mesh_instance)
	_preview_mesh_instances[tile_type] = mesh_instance

	var light = DirectionalLight3D.new()
	light.transform = Transform3D(Basis.from_euler(Vector3(-0.8, 0.6, 0.0)), Vector3.ZERO)
	light.light_energy = 1.2
	scene_root.add_child(light)

	var env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.12, 0.12, 0.12, 0.0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.4, 0.4, 0.4)
	env.ambient_light_energy = 1.0
	var world_env = WorldEnvironment.new()
	world_env.environment = env
	scene_root.add_child(world_env)

	var camera = Camera3D.new()
	var cam_forward = (CAM_TARGET - CAM_POSITION).normalized()
	var cam_right   = cam_forward.cross(Vector3.UP).normalized()
	var cam_up      = cam_right.cross(cam_forward).normalized()
	camera.transform = Transform3D(
		Basis(cam_right, cam_up, -cam_forward),
		CAM_POSITION
	)
	camera.fov = 40.0
	scene_root.add_child(camera)

	var label = Label.new()
	label.text = label_text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(label)

	button.pressed.connect(_on_tile_button_pressed.bind(tile_type, button))


func _on_tile_button_pressed(tile_type: int, pressed_button: Button) -> void:
	for child in grid_container.get_children():
		if child is Button and child != pressed_button:
			child.button_pressed = false
	tile_type_selected.emit(tile_type)


# ============================================================================
# MATERIAL PREVIEW UPDATE
# ============================================================================

# surface_materials: Array[StandardMaterial3D] — [top, sides, bottom]
func update_preview_materials(surface_materials: Array) -> void:
	for tile_type in _preview_mesh_instances:
		var mi: MeshInstance3D = _preview_mesh_instances[tile_type]
		if not mi or not mi.mesh:
			continue

		var surface_count = mi.mesh.get_surface_count()
		for i in range(surface_count):
			var mat_index = clampi(i, 0, surface_materials.size() - 1)
			if surface_materials[mat_index]:
				mi.set_surface_override_material(i, surface_materials[mat_index])

		var viewport = mi.get_parent().get_parent() as SubViewport
		if viewport:
			viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


# ============================================================================
# TOGGLE
# ============================================================================

func toggle():
	if tween:
		tween.kill()
	tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	var target_x = 0.0 if not is_open else panel_width - button_width
	tween.tween_property(panel, "position:x", target_x, 0.25)
	is_open = not is_open
	_update_toggle_button()


func _update_toggle_button():
	toggle_button.text = "<" if is_open else ">"


# ============================================================================
# SIGNAL HANDLERS
# ============================================================================

func _on_toggle_button_pressed():
	toggle()
