class_name CameraController extends Camera3D

@onready var camera: CameraController = $"."

# Camera rotation state
var camera_rotation : Vector2 = Vector2.ZERO  # x = pitch, y = yaw
var mouse_sensitivity : float = 0.003
var movement_speed : float = 5.0

func _ready():
	camera.position = Vector3(0,5,0)

func _process(delta):
	handle_movement(delta)
	handle_rotation()

func handle_movement(delta):
	var input = Vector3.ZERO
	
	if Input.is_key_pressed(KEY_W): input.z -= 1
	if Input.is_key_pressed(KEY_S): input.z += 1
	if Input.is_key_pressed(KEY_A): input.x -= 1
	if Input.is_key_pressed(KEY_D): input.x += 1
	if Input.is_key_pressed(KEY_Q): input.y -= 1
	if Input.is_key_pressed(KEY_E): input.y += 1
	
	# Move relative to camera direction
	var direction = (global_transform.basis * input).normalized()
	global_translate(direction * movement_speed * delta)

func handle_rotation():
	# Apply rotation to camera
	rotation.y = camera_rotation.y
	rotation.x = camera_rotation.x

func handle_mouse_motion(event: InputEventMouseMotion):
	if not Engine.is_editor_hint():
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE):
			camera_rotation.y -= event.relative.x * mouse_sensitivity
			camera_rotation.x -= event.relative.y * mouse_sensitivity
			camera_rotation.x = clamp(camera_rotation.x, -PI/2, PI/2)

func handle_mouse_wheel(delta: float):
	fov = clamp(fov + delta, 1.0, 179.0)

func reset_fov():
	fov = 75.0
