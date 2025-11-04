class_name Inventory extends Node

@export var inventory : Dictionary[Item, int] = {}

func add_item(item : Item, count : int) -> void:
	if inventory.has(item):
		inventory[item] += count
	else:
		inventory.set(item, count)

func subtract_item(item: Item, count: int) -> void:
	if inventory.has(item):
		if inventory[item] - count > 0:
			inventory[item] -= count
		else:
			print_debug("Can't subtract below 0!")
			return
	else:
		print_debug("Inventory doesn't have item!")
		return

func remove_item_from_dictionary(item: Item) -> void:
	inventory.erase(item)

func get_inventory() -> Dictionary:
	return inventory
