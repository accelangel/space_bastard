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
	zoom_min = calculate_working_min_zoom()
	
	# Set initial zoom to 95% zoomed out (5% larger than minimum)
	var initial_zoom = zoom_min * 1.05
	zoom = initial_zoom
	zoomTarget = initial_zoom
	
	print("Map size: ", map_size)
	print("Viewport size: ", get_viewport_rect().size)
	print("Working min zoom: ", zoom_min)
	print("Starting zoom (95% zoomed out): ", zoom)

func _process(delta):
	Zoom(delta)
	Pan(delta)
	ClickAndDrag()
	
	# Simple position clamping to prevent going outside map
	clamp_position_to_map()

func calculate_working_min_zoom() -> Vector2:
	var viewport_size = get_viewport_rect().size
	
	# Calculate theoretical minimum
	var zoom_for_width = viewport_size.x / map_size.x
	var zoom_for_height = viewport_size.y / map_size.y
	var theoretical_min = min(zoom_for_width, zoom_for_height)
	
	print("Theoretical min zoom: ", theoretical_min)
	
	# Your original working value was 0.01397, which is about 95.3% of theoretical
	# Let's use a similar ratio but calculate it dynamically
	var working_zoom = theoretical_min * 0.953
	
	# Alternative: use a slightly cleaner version of your hardcoded value
	# For 1920x1080 viewport, this should be very close to 0.01397
	var alternative_zoom = theoretical_min * 0.95
	
	print("Calculated working zoom (95.3%): ", working_zoom)
	print("Alternative working zoom (95%): ", alternative_zoom)
	
	# Use the 95% version as it's cleaner
	return Vector2(alternative_zoom, alternative_zoom)

func clamp_position_to_map():
	# Calculate how much of the map we can see at current zoom
	var viewport_size = get_viewport_rect().size
	var visible_world_size = viewport_size / zoom
	
	# Calculate the maximum distance the camera can be from center
	var max_offset = (map_size - visible_world_size) / 2.0
	
	# Only clamp if we're more zoomed in than the minimum
	if max_offset.x > 0:
		position.x = clamp(position.x, -max_offset.x, max_offset.x)
	else:
		position.x = 0  # Center if fully zoomed out
		
	if max_offset.y > 0:
		position.y = clamp(position.y, -max_offset.y, max_offset.y)
	else:
		position.y = 0  # Center if fully zoomed out

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
		zoomTarget = Vector2(
			clamp(zoomTarget.x, zoom_min.x, zoom_max.x),
			clamp(zoomTarget.y, zoom_min.y, zoom_max.y)
		)
		
		# Debug: check if zoom is being clamped
		if old_target != zoomTarget:
			print("Zoom clamped from ", old_target, " to ", zoomTarget, " (min: ", zoom_min, ")")
	
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

# Debug function you can call
func debug_current_state():
	var viewport_size = get_viewport_rect().size
	var visible_world_size = viewport_size / zoom
	var coverage_x = visible_world_size.x / map_size.x
	var coverage_y = visible_world_size.y / map_size.y
	
	print("=== CAMERA DEBUG ===")
	print("Current zoom: ", zoom)
	print("Visible world size: ", visible_world_size)
	print("Map coverage X: ", coverage_x * 100, "%")
	print("Map coverage Y: ", coverage_y * 100, "%")
	print("Position: ", position)
	print("====================")

# If you want to go back to your exact hardcoded value
func use_hardcoded_zoom():
	zoom_min = Vector2(0.01397, 0.01397)
	if zoom.x < zoom_min.x:
		zoom = zoom_min * 1.05
		zoomTarget = zoom
	print("Reverted to hardcoded zoom: ", zoom_min)
