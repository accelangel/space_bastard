extends Camera2D

# Map configuration
var map_size = Vector2(131072, 73728)
var zoom_min: Vector2
var zoom_max: Vector2 = Vector2(5, 5)

# Zoom system variables
var zoom_start_mouse_pos = Vector2.ZERO
var zoom_start_screen_pos = Vector2.ZERO
@export var zoomSpeed: float = 11
var zoomTarget: Vector2

# Click and drag variables
var dragStartMousePos = Vector2.ZERO
var dragStartCameraPos = Vector2.ZERO
var isDragging: bool = false

func _ready():
	zoomTarget = zoom
	zoom_min = calculate_min_zoom()
	print("Map size: ", map_size)
	print("Viewport size: ", get_viewport_rect().size)
	print("Calculated min zoom: ", zoom_min)
	print("Current zoom: ", zoom)
	print("Zoom target: ", zoomTarget)

func _process(delta):
	Zoom(delta)
	Pan(delta)
	ClickAndDrag()

func Zoom(delta):
	var scroll = 0
	if Input.is_action_just_pressed("camera_zoom_in"):
		scroll = 1
	elif Input.is_action_just_pressed("camera_zoom_out"):
		scroll = -1
	
	if scroll != 0:
		var zoom_factor = 1.1 ** scroll
		zoom_start_mouse_pos = get_global_mouse_position()
		zoom_start_screen_pos = Vector2(get_viewport().get_mouse_position())
		
		var old_target = zoomTarget
		zoomTarget *= zoom_factor
		zoomTarget = clamp(zoomTarget, zoom_min, zoom_max)
		
		# Debug: check if zoom is being clamped
		#if old_target != zoomTarget:
			#print("Zoom clamped from ", old_target, " to ", zoomTarget, " (min: ", zoom_min, ")")
	
	# Smooth interpolation toward target zoom
	if zoom.distance_to(zoomTarget) > 0.001:
		var mouse_world_before = zoom_start_mouse_pos
		zoom = zoom.slerp(zoomTarget, zoomSpeed * delta)
		
		var viewport_center = Vector2(get_viewport().size) / 2
		var mouse_world_after = position + (zoom_start_screen_pos - viewport_center) / zoom
		
		position += mouse_world_before - mouse_world_after

func Pan(delta):
	var moveAmount = Vector2.ZERO
	if Input.is_action_pressed("camera_move_right"):
		moveAmount.x += 1
	if Input.is_action_pressed("camera_move_left"):
		moveAmount.x -= 1
	if Input.is_action_pressed("camera_move_up"):
		moveAmount.y -= 1
	if Input.is_action_pressed("camera_move_down"):
		moveAmount.y += 1
	
	moveAmount = moveAmount.normalized()
	position += moveAmount * delta * 1000 * (1 / zoom.x)

func ClickAndDrag():
	if !isDragging and Input.is_action_just_pressed("camera_pan"):
		dragStartMousePos = get_viewport().get_mouse_position()
		dragStartCameraPos = position
		isDragging = true
	
	if isDragging and Input.is_action_just_released("camera_pan"):
		isDragging = false
	
	if isDragging:
		var moveVector = get_viewport().get_mouse_position() - dragStartMousePos
		position = dragStartCameraPos - moveVector * (1 / zoom.x)

func calculate_min_zoom():
	var viewport_size = get_viewport_rect().size
	
	# Calculate zoom needed to fit width and height
	var zoom_for_width = viewport_size.x / map_size.x
	var zoom_for_height = viewport_size.y / map_size.y
	
	# Use the smaller zoom value to ensure the entire map fits
	var required_zoom = min(zoom_for_width, zoom_for_height)
	
	# Instead of a random buffer, use a slightly smaller "clean" float
	# 0.0146484375 is 3/512, let's use something slightly smaller but cleaner
	var clean_zoom = 0.01397  # Nice round number, slightly less than calculated
	
	print("Calculated zoom: ", required_zoom)
	print("Using clean zoom: ", clean_zoom)
	
	return Vector2(clean_zoom, clean_zoom)
