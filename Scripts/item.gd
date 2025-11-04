class_name Item extends Resource

@export var name : String = ""
@export var texture : Texture2D = PlaceholderTexture2D.new()
@export var elements : Array[ElementalType]
@export var flavor_text : JSON

#@export_group("Optional")
#@export var effects : Array[StatusEffects]
"""
# Add this method to properly compare items by name
func _equals(other_item: Item) -> bool:
	if not other_item:
		return false
	return name == other_item.name

# Override the == operator
func _operator_equal(other_item) -> bool:
	if other_item is Item:
		return _equals(other_item)
	return false
"""
