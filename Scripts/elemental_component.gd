extends Node

var arr : Array[ElementalType]

##Clears the elements array
func clear_arr() -> void:
	arr.clear()

##Pushes new element to front of the array
func add_element(element : ElementalType) -> void:
	arr.push_back(element)

func get_elements() -> Array[ElementalType]:
	return arr
