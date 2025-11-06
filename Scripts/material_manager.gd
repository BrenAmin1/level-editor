class_name MaterialManager extends RefCounted

# References to parent TileMap3D data
var custom_meshes: Dictionary  # Reference to TileMap3D.custom_meshes
var custom_materials: Dictionary  # Reference to TileMap3D.custom_materials
var tiles: Dictionary  # Reference to TileMap3D.tiles
var tile_map: TileMap3D  # Reference to parent for calling update_tile_mesh

# ============================================================================
# SETUP
# ============================================================================

func setup(tilemap: TileMap3D, meshes_ref: Dictionary, materials_ref: Dictionary, tiles_ref: Dictionary):
	tile_map = tilemap
	custom_meshes = meshes_ref
	custom_materials = materials_ref
	tiles = tiles_ref

# ============================================================================
# MATERIAL MANAGEMENT FUNCTIONS
# ============================================================================

# Set material for a specific surface of a custom mesh
func set_custom_material(tile_type: int, surface_index: int, material: StandardMaterial3D) -> bool:
	if tile_type not in custom_meshes:
		push_error("No custom mesh for tile type: " + str(tile_type))
		return false
	
	var mesh = custom_meshes[tile_type]
	if surface_index < 0 or surface_index >= mesh.get_surface_count():
		push_error("Surface index " + str(surface_index) + " out of range. Mesh has " + str(mesh.get_surface_count()) + " surfaces")
		return false
	
	# Update materials array
	if tile_type not in custom_materials:
		custom_materials[tile_type] = []
	
	# Ensure array is large enough
	while custom_materials[tile_type].size() < mesh.get_surface_count():
		custom_materials[tile_type].append(null)
	
	custom_materials[tile_type][surface_index] = material
	
	# Apply to the base mesh
	mesh.surface_set_material(surface_index, material)
	
	# Update all tiles using this mesh type
	for pos in tiles:
		if tiles[pos] == tile_type:
			tile_map.update_tile_mesh(pos)
	
	print("✓ Material updated for tile type ", tile_type, " surface ", surface_index)
	return true


# Get the number of surfaces (material slots) for a tile type
func get_surface_count(tile_type: int) -> int:
	if tile_type in custom_meshes:
		return custom_meshes[tile_type].get_surface_count()
	return 0


# Get material for a specific surface
func get_custom_material(tile_type: int, surface_index: int) -> Material:
	if tile_type in custom_materials and surface_index < custom_materials[tile_type].size():
		return custom_materials[tile_type][surface_index]
	elif tile_type in custom_meshes:
		var mesh = custom_meshes[tile_type]
		if surface_index < mesh.get_surface_count():
			return mesh.surface_get_material(surface_index)
	return null


# Create a material with custom properties
func create_custom_material(albedo_color: Color, metallic: float = 0.0, 
						   roughness: float = 1.0, emission: Color = Color.BLACK) -> StandardMaterial3D:
	var material = StandardMaterial3D.new()
	material.albedo_color = albedo_color
	material.metallic = metallic
	material.roughness = roughness
	material.emission_enabled = emission != Color.BLACK
	material.emission = emission
	material.cull_mode = BaseMaterial3D.CULL_BACK
	return material
