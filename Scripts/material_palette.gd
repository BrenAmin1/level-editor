extends FoldableContainer

signal ui_hover_changed(is_hovered: bool)

var is_mouse_inside: bool = false

func _ready():
	mouse_filter = Control.MOUSE_FILTER_STOP


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
