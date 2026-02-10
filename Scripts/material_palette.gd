extends FoldableContainer

signal ui_hover_changed(is_hovered: bool)
signal material_selected(material_index: int)

var is_mouse_inside: bool = false
var materials: Array[Dictionary] = []
var selected_material_index: int = -1

@onready var add_material_button: Button = %AddMaterialButton
@onready var edit_material_button: Button = %EditMaterialButton
@onready var delete_material_button: Button = %DeleteMaterialButton
@onready var material_grid: GridContainer = %MaterialGrid
@onready var material_maker_popup: PopupPanel = %MaterialMakerPopup

# Preload the material card scene
const MATERIAL_CARD_SCENE = preload("res://Scenes/material_card.tscn")

func _ready():
	mouse_filter = Control.MOUSE_FILTER_STOP
	
	# Connect button signals
	add_material_button.pressed.connect(_on_add_material_pressed)
	edit_material_button.pressed.connect(_on_edit_material_pressed)
	delete_material_button.pressed.connect(_on_delete_material_pressed)
	
	# Connect popup signal
	if material_maker_popup:
		material_maker_popup.material_created.connect(_on_material_created)
	
	# Initially disable edit/delete buttons
	edit_material_button.disabled = true
	delete_material_button.disabled = true
	
	# Clear the default material card from the grid
	for child in material_grid.get_children():
		child.queue_free()
	
	# Add some default materials for testing
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


func _on_add_material_pressed() -> void:
	if material_maker_popup:
		material_maker_popup.popup_centered()


func _on_edit_material_pressed() -> void:
	if selected_material_index >= 0 and selected_material_index < materials.size():
		# Pass the material data dictionary to the popup
		if material_maker_popup:
			material_maker_popup.edit_material(materials[selected_material_index].data)


func _on_delete_material_pressed() -> void:
	if selected_material_index >= 0 and selected_material_index < materials.size():
		_delete_material(selected_material_index)


func _on_material_created(material_dict: Dictionary) -> void:
	print("Material created: ", material_dict.name)
	
	# Create actual Godot material resource from the data
	var godot_material = _create_godot_material(material_dict)
	
	# Store both the data and the material resource
	var material_entry = {
		"data": material_dict,
		"resource": godot_material
	}
	materials.append(material_entry)
	
	# Create visual card for the material
	_create_material_card(material_dict, materials.size() - 1)


func _create_godot_material(material_dict: Dictionary) -> StandardMaterial3D:
	"""Convert material data dictionary into a Godot StandardMaterial3D"""
	var m_material = StandardMaterial3D.new()
	
	# Apply settings to match your existing materials
	m_material.uv1_triplanar = true
	m_material.uv1_world_triplanar = true
	m_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST  # Pixel art look
	
	# Load textures and apply to material
	# For now, we'll use the top texture as the main albedo
	var texture_path = material_dict.get("top_texture", "")
	if texture_path != "" and FileAccess.file_exists(texture_path):
		var texture = load(texture_path) as Texture2D
		if texture:
			m_material.albedo_texture = texture
	elif material_dict.get("side_texture", "") != "":
		# Fallback to side texture if no top texture
		texture_path = material_dict.get("side_texture", "")
		if FileAccess.file_exists(texture_path):
			var texture = load(texture_path) as Texture2D
			if texture:
				m_material.albedo_texture = texture
	
	# Load normal map
	var normal_path = material_dict.get("top_normal", "")
	if normal_path != "" and FileAccess.file_exists(normal_path):
		var normal = load(normal_path) as Texture2D
		if normal:
			m_material.normal_enabled = true
			m_material.normal_texture = normal
	
	# Set a default color based on material name if no texture
	if m_material.albedo_texture == null:
		var mat_name = material_dict.get("name", "").to_lower()
		if mat_name.contains("grass"):
			m_material.albedo_color = Color(0.3, 0.6, 0.2)
		elif mat_name.contains("dirt"):
			m_material.albedo_color = Color(0.5, 0.35, 0.2)
		elif mat_name.contains("stone"):
			m_material.albedo_color = Color(0.5, 0.5, 0.5)
		elif mat_name.contains("gravel"):
			m_material.albedo_color = Color(0.6, 0.6, 0.6)
	
	# Optional: Save the material as a resource file
	#var save_path = "res://materials/" + material_dict.name.to_lower().replace(" ", "_") + ".tres"
	# Uncomment to save: ResourceSaver.save(material, save_path)
	
	return m_material


func _create_material_card(material_dict: Dictionary, index: int) -> void:
	var card = MATERIAL_CARD_SCENE.instantiate()
	material_grid.add_child(card)
	
	# Set the custom minimum size
	card.custom_minimum_size = Vector2(96, 128)
	
	# Setup the card
	if card.has_method("setup"):
		card.setup(material_dict, index)
	
	# Connect selection signal
	card.material_card_selected.connect(_on_material_card_selected)


func _on_material_card_selected(index: int) -> void:
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
	
	# Enable edit/delete buttons
	edit_material_button.disabled = false
	delete_material_button.disabled = false
	
	# Emit signal for level editor to use
	material_selected.emit(index)
	
	print("Material selected: ", materials[index].data.name)


func _get_card_at_index(index: int) -> Control:
	if index >= 0 and index < material_grid.get_child_count():
		return material_grid.get_child(index)
	return null


func _delete_material(index: int) -> void:
	if index >= 0 and index < materials.size():
		# Remove from array
		materials.remove_at(index)
		
		# Remove card from grid
		var card = material_grid.get_child(index)
		if card:
			card.queue_free()
		
		# Update indices of remaining cards
		_refresh_card_indices()
		
		# Clear selection
		selected_material_index = -1
		edit_material_button.disabled = true
		delete_material_button.disabled = true
		
		print("Material deleted")


func _refresh_card_indices() -> void:
	for i in range(material_grid.get_child_count()):
		var card = material_grid.get_child(i)
		if card and card.has_method("update_index"):
			card.update_index(i)


func _add_default_materials() -> void:
	# Add default materials using your existing textures
	var default_grass_data = {
		"name": "Grass",
		"top_texture": "res://Images/Grass_3.png",
		"top_normal": "res://Images/Grass_3_n.png",
		"side_texture": "res://Images/Grass_3.png",
		"side_normal": "res://Images/Grass_3_n.png",
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
	
	# Create Godot materials for the defaults
	var grass_material = _create_godot_material(default_grass_data)
	var dirt_material = _create_godot_material(default_dirt_data)
	var gravel_material = _create_godot_material(default_gravel_data)
	
	# Store as material entries
	materials.append({"data": default_grass_data, "resource": grass_material})
	materials.append({"data": default_dirt_data, "resource": dirt_material})
	materials.append({"data": default_gravel_data, "resource": gravel_material})
	
	_create_material_card(default_grass_data, 0)
	_create_material_card(default_dirt_data, 1)
	_create_material_card(default_gravel_data, 2)


func get_selected_material() -> StandardMaterial3D:
	"""Get the actual Godot material resource for the selected material"""
	if selected_material_index >= 0 and selected_material_index < materials.size():
		return materials[selected_material_index].resource
	return null


func get_selected_material_data() -> Dictionary:
	"""Get the material data dictionary for the selected material"""
	if selected_material_index >= 0 and selected_material_index < materials.size():
		return materials[selected_material_index].data
	return {}


func get_material_at_index(index: int) -> StandardMaterial3D:
	"""Get the Godot material resource at a specific index"""
	if index >= 0 and index < materials.size():
		return materials[index].resource
	return null


func get_material_data_at_index(index: int) -> Dictionary:
	"""Get the material data dictionary at a specific index"""
	if index >= 0 and index < materials.size():
		return materials[index].data
	return {}
