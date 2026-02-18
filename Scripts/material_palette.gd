extends FoldableContainer

signal ui_hover_changed(is_hovered: bool)
signal material_selected(material_index: int)
signal popup_state_changed(is_open: bool)

var is_mouse_inside: bool = false
var materials: Array[Dictionary] = []
var selected_material_index: int = -1

@onready var add_material_button: Button = %AddMaterialButton
@onready var edit_material_button: Button = %EditMaterialButton
@onready var delete_material_button: Button = %DeleteMaterialButton
@onready var save_palette_button: Button = %SaveButton
@onready var load_palette_button: Button = %LoadButton
@onready var material_grid: GridContainer = %MaterialGrid
@onready var material_maker_popup: PopupPanel = %MaterialMakerPopup

const MATERIAL_CARD_SCENE = preload("res://Scenes/material_card.tscn")

var save_palette_dialog: FileDialog
var load_palette_dialog: FileDialog

func _ready():
	mouse_filter = Control.MOUSE_FILTER_STOP
	
	add_material_button.pressed.connect(_on_add_material_pressed)
	edit_material_button.pressed.connect(_on_edit_material_pressed)
	delete_material_button.pressed.connect(_on_delete_material_pressed)
	save_palette_button.pressed.connect(_on_save_palette_pressed)
	load_palette_button.pressed.connect(_on_load_palette_pressed)
	
	# FIXED: Connect material_edited signal
	if material_maker_popup:
		material_maker_popup.material_created.connect(_on_material_created)
		material_maker_popup.material_edited.connect(_on_material_edited)
		material_maker_popup.popup_opened.connect(_on_popup_opened)
		material_maker_popup.popup_closed.connect(_on_popup_closed)
	
	_setup_palette_dialogs()
	
	edit_material_button.disabled = true
	delete_material_button.disabled = true
	
	for child in material_grid.get_children():
		child.queue_free()
	
	_add_default_materials()


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


# ============================================================================
# PALETTE FILE DIALOGS SETUP
# ============================================================================

func _setup_palette_dialogs():
	_ensure_palette_directory()
	
	save_palette_dialog = FileDialog.new()
	add_child(save_palette_dialog)
	save_palette_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	save_palette_dialog.access = FileDialog.ACCESS_FILESYSTEM
	save_palette_dialog.filters = PackedStringArray(["*.palette.json ; Material Palette"])
	save_palette_dialog.file_selected.connect(_on_palette_save_confirmed)
	save_palette_dialog.current_dir = ProjectSettings.globalize_path("user://saved_palettes/")
	save_palette_dialog.use_native_dialog = true
	
	load_palette_dialog = FileDialog.new()
	add_child(load_palette_dialog)
	load_palette_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	load_palette_dialog.access = FileDialog.ACCESS_FILESYSTEM
	load_palette_dialog.filters = PackedStringArray(["*.palette.json ; Material Palette"])
	load_palette_dialog.file_selected.connect(_on_palette_load_confirmed)
	load_palette_dialog.current_dir = ProjectSettings.globalize_path("user://saved_palettes/")
	load_palette_dialog.use_native_dialog = true


func _ensure_palette_directory():
	var dir = DirAccess.open("user://")
	if dir and not dir.dir_exists("saved_palettes"):
		var err = dir.make_dir("saved_palettes")
		if err == OK:
			print("Created saved_palettes directory")
		else:
			push_error("Failed to create saved_palettes directory: ", err)


# ============================================================================
# BUTTON CALLBACKS
# ============================================================================

func _on_add_material_pressed() -> void:
	if material_maker_popup:
		material_maker_popup.popup_centered()


# FIXED: Pass index when editing
func _on_edit_material_pressed() -> void:
	if selected_material_index >= 0 and selected_material_index < materials.size():
		if material_maker_popup:
			material_maker_popup.edit_material(materials[selected_material_index].data, selected_material_index)


func _on_delete_material_pressed() -> void:
	if selected_material_index >= 0 and selected_material_index < materials.size():
		_delete_material(selected_material_index)


func _on_save_palette_pressed() -> void:
	save_palette_dialog.popup_centered_ratio(0.6)


func _on_load_palette_pressed() -> void:
	load_palette_dialog.popup_centered_ratio(0.6)


func _on_material_created(material_dict: Dictionary) -> void:
	print("Material created: ", material_dict.name)
	
	var surface_resources = _create_surface_resources(material_dict)

	var material_entry = {
		"data": material_dict,
		"resource": surface_resources[0],       # TOP  - used for card display / legacy callers
		"surface_resources": surface_resources  # [top, sides, bottom]
	}
	materials.append(material_entry)
	
	_create_material_card(material_dict, materials.size() - 1)


# FIXED: New handler for editing materials
func _on_material_edited(index: int, material_dict: Dictionary) -> void:
	if index >= 0 and index < materials.size():
		print("Material edited at index ", index, ": ", material_dict.name)
		
		# Create updated Godot material resources (one per surface)
		var surface_resources = _create_surface_resources(material_dict)

		# Update the materials array
		materials[index] = {
			"data": material_dict,
			"resource": surface_resources[0],
			"surface_resources": surface_resources
		}
		
		# Update the card
		var card = _get_card_at_index(index)
		if card and card.has_method("setup"):
			card.setup(material_dict, index)


func _on_popup_opened() -> void:
	popup_state_changed.emit(true)


func _on_popup_closed() -> void:
	popup_state_changed.emit(false)


# ============================================================================
# PALETTE SAVE/LOAD
# ============================================================================

func _on_palette_save_confirmed(path: String) -> void:
	if save_palette(path):
		print("\n=== PALETTE SAVED ===")
		print("Saved to: ", path)
		print("Materials: ", materials.size())
		print("=====================\n")
	else:
		push_error("Failed to save palette")


func _on_palette_load_confirmed(path: String) -> void:
	if load_palette(path):
		print("\n=== PALETTE LOADED ===")
		print("Loaded from: ", path)
		print("Materials: ", materials.size())
		print("======================\n")
	else:
		push_error("Failed to load palette")


func save_palette(filepath: String) -> bool:
	var palette_data = {
		"version": 1,
		"materials": []
	}
	
	for material_entry in materials:
		palette_data["materials"].append(material_entry["data"])
	
	var json_string = JSON.stringify(palette_data, "\t")
	var file = FileAccess.open(filepath, FileAccess.WRITE)
	
	if file == null:
		push_error("Failed to open file for writing: " + filepath)
		return false
	
	file.store_string(json_string)
	file.close()
	
	return true


func load_palette(filepath: String) -> bool:
	var file = FileAccess.open(filepath, FileAccess.READ)
	
	if file == null:
		push_error("Failed to open file for reading: " + filepath)
		return false
	
	var json_string = file.get_as_text()
	file.close()
	
	var json = JSON.new()
	var parse_result = json.parse(json_string)
	
	if parse_result != OK:
		push_error("Failed to parse JSON: " + json.get_error_message())
		return false
	
	var palette_data = json.data
	
	if not palette_data is Dictionary or not palette_data.has("materials"):
		push_error("Invalid palette file format")
		return false
	
	_clear_all_materials()
	
	for material_data in palette_data["materials"]:
		if material_data is Dictionary:
			_on_material_created(material_data)
	
	return true


func _clear_all_materials() -> void:
	materials.clear()
	
	for child in material_grid.get_children():
		child.queue_free()
	
	selected_material_index = -1
	edit_material_button.disabled = true
	delete_material_button.disabled = true


# ============================================================================
# MATERIAL CREATION AND MANAGEMENT
# ============================================================================

func _create_godot_material(material_dict: Dictionary) -> StandardMaterial3D:
	# Convenience wrapper - returns the top-surface material.
	# Used for display (material cards, selection, etc.)
	return _create_godot_material_for_surface(material_dict, 0)


func _create_godot_material_for_surface(material_dict: Dictionary, surface_idx: int) -> StandardMaterial3D:
	# surface_idx matches MeshGenerator.SurfaceType: 0 = TOP, 1 = SIDES, 2 = BOTTOM
	var m_material = StandardMaterial3D.new()
	m_material.uv1_triplanar = true
	m_material.uv1_world_triplanar = true
	m_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST

	# Pick texture/normal keys based on which surface we are building for.
	var texture_key: String
	var normal_key: String
	match surface_idx:
		1:  # SIDES
			texture_key = "side_texture"
			normal_key  = "side_normal"
		2:  # BOTTOM
			texture_key = "bottom_texture"
			normal_key  = "bottom_normal"
		_:  # TOP (0) and any unknown surface
			texture_key = "top_texture"
			normal_key  = "top_normal"

	# Load albedo texture, falling back through top -> side -> bottom if missing.
	var texture_path = material_dict.get(texture_key, "")
	if texture_path == "" or not FileAccess.file_exists(texture_path):
		for fallback_key in ["top_texture", "side_texture", "bottom_texture"]:
			var fp = material_dict.get(fallback_key, "")
			if fp != "" and FileAccess.file_exists(fp):
				texture_path = fp
				break

	if texture_path != "" and FileAccess.file_exists(texture_path):
		var texture = load(texture_path) as Texture2D
		if texture:
			m_material.albedo_texture = texture

	# Load normal map, falling back to any available normal.
	var normal_path = material_dict.get(normal_key, "")
	if normal_path == "" or not FileAccess.file_exists(normal_path):
		for fallback_key in ["top_normal", "side_normal", "bottom_normal"]:
			var fp = material_dict.get(fallback_key, "")
			if fp != "" and FileAccess.file_exists(fp):
				normal_path = fp
				break

	if normal_path != "" and FileAccess.file_exists(normal_path):
		var normal_map = load(normal_path) as Texture2D
		if normal_map:
			m_material.normal_enabled = true
			m_material.normal_texture = normal_map

	# Fallback colour if no texture loaded.
	if m_material.albedo_texture == null:
		if material_dict.get("name", "").to_lower().contains("grass"):
			m_material.albedo_color = Color(0.3, 0.6, 0.3)
		elif material_dict.get("name", "").to_lower().contains("dirt"):
			m_material.albedo_color = Color(0.5, 0.3, 0.2)
		else:
			m_material.albedo_color = Color(0.6, 0.6, 0.6)

	return m_material


func _create_surface_resources(material_dict: Dictionary) -> Array[StandardMaterial3D]:
	# Returns [top_material, sides_material, bottom_material] in SurfaceType order.
	return [
		_create_godot_material_for_surface(material_dict, 0),
		_create_godot_material_for_surface(material_dict, 1),
		_create_godot_material_for_surface(material_dict, 2),
	]


func _create_material_card(material_dict: Dictionary, index: int) -> void:
	var card = MATERIAL_CARD_SCENE.instantiate()
	material_grid.add_child(card)
	
	card.custom_minimum_size = Vector2(96, 128)
	
	if card.has_method("setup"):
		card.setup(material_dict, index)
	
	card.material_card_selected.connect(_on_material_card_selected)


func _on_material_card_selected(index: int) -> void:
	# FIXED: Bounds checking
	if index < 0 or index >= materials.size():
		print("ERROR: Card index out of bounds: ", index, " (materials.size = ", materials.size(), ")")
		return
	
	# Deselect previous card
	if selected_material_index >= 0:
		var prev_card = _get_card_at_index(selected_material_index)
		if prev_card and prev_card.has_method("set_selected"):
			prev_card.set_selected(false)
	
	# Select new card
	selected_material_index = index
	var new_card = _get_card_at_index(index)
	if new_card and new_card.has_method("set_selected"):
		new_card.set_selected(true)
	
	edit_material_button.disabled = false
	delete_material_button.disabled = false
	
	material_selected.emit(index)
	
	print("Material selected: ", materials[index].data.name)


func _get_card_at_index(index: int) -> Control:
	if index >= 0 and index < material_grid.get_child_count():
		return material_grid.get_child(index)
	return null


# FIXED: Proper deletion with async handling
func _delete_material(index: int) -> void:
	if index >= 0 and index < materials.size():
		print("Deleting material at index ", index)
		
		# Remove from array first
		materials.remove_at(index)
		
		# Remove card from grid
		var card = material_grid.get_child(index)
		if card:
			card.queue_free()
		
		# IMPORTANT: Wait a frame for queue_free to process
		await get_tree().process_frame
		
		# Update indices of remaining cards
		_refresh_card_indices()
		
		# Clear selection
		selected_material_index = -1
		edit_material_button.disabled = true
		delete_material_button.disabled = true
		
		print("Material deleted, ", materials.size(), " materials remaining")


func _refresh_card_indices() -> void:
	for i in range(material_grid.get_child_count()):
		var card = material_grid.get_child(i)
		if card and card.has_method("update_index"):
			card.update_index(i)


# ============================================================================
# DEFAULT MATERIALS
# ============================================================================

func _add_default_materials() -> void:
	var default_grass_data = {
		"name": "Grass",
		"top_texture": "res://Images/Grass.png",
		"top_normal": "",
		"side_texture": "res://Images/dirt.png",
		"side_normal": "",
		"bottom_texture": "res://Images/dirt.png",
		"bottom_normal": "res://Images/dirt_n.png"
	}
	
	var default_dirt_data = {
		"name": "Dirt",
		"top_texture": "res://Images/dirt.png",
		"top_normal": "res://Images/dirt_n.png",
		"side_texture": "res://Images/dirt.png",
		"side_normal": "res://Images/dirt_n.png",
		"bottom_texture": "res://Images/dirt.png",
		"bottom_normal": "res://Images/dirt_n.png"
	}
	
	var default_gravel_data = {
		"name": "Gravel",
		"top_texture": "res://Images/Gravle_3.png",
		"top_normal": "",
		"side_texture": "res://Images/Gravle_3.png",
		"side_normal": "",
		"bottom_texture": "res://Images/Gravle_3.png",
		"bottom_normal": ""
	}
	
	var grass_resources = _create_surface_resources(default_grass_data)
	var dirt_resources = _create_surface_resources(default_dirt_data)
	var gravel_resources = _create_surface_resources(default_gravel_data)

	materials.append({"data": default_grass_data, "resource": grass_resources[0], "surface_resources": grass_resources})
	materials.append({"data": default_dirt_data, "resource": dirt_resources[0], "surface_resources": dirt_resources})
	materials.append({"data": default_gravel_data, "resource": gravel_resources[0], "surface_resources": gravel_resources})
	
	_create_material_card(default_grass_data, 0)
	_create_material_card(default_dirt_data, 1)
	_create_material_card(default_gravel_data, 2)


# ============================================================================
# PUBLIC API FOR LEVEL EDITOR
# ============================================================================

func get_selected_material() -> StandardMaterial3D:
	if selected_material_index >= 0 and selected_material_index < materials.size():
		return materials[selected_material_index].resource
	return null


func get_selected_material_data() -> Dictionary:
	if selected_material_index >= 0 and selected_material_index < materials.size():
		return materials[selected_material_index].data
	return {}


func get_material_at_index(index: int) -> StandardMaterial3D:
	# Returns the top-surface material. Kept for backwards compatibility.
	if index >= 0 and index < materials.size():
		return materials[index].resource
	return null


func get_material_for_surface(index: int, surface_idx: int) -> StandardMaterial3D:
	# Returns the correct material for a specific mesh surface.
	# surface_idx: 0 = TOP, 1 = SIDES, 2 = BOTTOM (matches MeshGenerator.SurfaceType)
	if index < 0 or index >= materials.size():
		return null
	var entry = materials[index]
	if entry.has("surface_resources"):
		var surface_resources: Array = entry["surface_resources"]
		if surface_idx >= 0 and surface_idx < surface_resources.size():
			return surface_resources[surface_idx]
	# Fallback for entries created before this change (no surface_resources key).
	return entry.resource


func get_material_data_at_index(index: int) -> Dictionary:
	if index >= 0 and index < materials.size():
		return materials[index].data
	return {}
