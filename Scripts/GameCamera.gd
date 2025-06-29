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
	
	# Calculate theoretical minimum - this should show exactly the map edges
	var zoom_for_width = viewport_size.x / map_size.x
	var zoom_for_height = viewport_size.y / map_size.y
	var theoretical_min = min(zoom_for_width, zoom_for_height)
	
	print("Viewport size: ", viewport_size)
	print("Map size: ", map_size)
	print("Zoom for width: ", zoom_for_width)
	print("Zoom for height: ", zoom_for_height)
	print("Theoretical min zoom: ", theoretical_min)
	
	# Use the EXACT theoretical minimum - this should show the entire map
	# Any floating-point precision issues will be handled by clamping
	var working_zoom = theoretical_min
	
	print("Using exact theoretical zoom: ", working_zoom)
	
	return Vector2(working_zoom, working_zoom)

func clamp_position_to_map():
	# Calculate how much of the map we can see at current zoom
	var viewport_size = get_viewport_rect().size
	var visible_world_size = viewport_size / zoom
	
	# Your map extends from -65536 to +65536 (width) and -36864 to +36864 (height)
	# So the map bounds are centered at origin
	var map_half_width = map_size.x / 2.0   # 65536
	var map_half_height = map_size.y / 2.0  # 36864
	
	# Calculate how far the camera can move from center before showing edge
	var view_half_width = visible_world_size.x / 2.0
	var view_half_height = visible_world_size.y / 2.0
	
	# Maximum offset from center = map_half - view_half
	# Add a tiny epsilon to handle floating-point precision issues
	var epsilon = 0.1  # Small buffer to prevent showing outside area
	var max_offset_x = max(0, map_half_width - view_half_width - epsilon)
	var max_offset_y = max(0, map_half_height - view_half_height - epsilon)
	
	# Debug information
	if Engine.get_process_frames() % 120 == 0:  # Every 2 seconds
		print("=== CLAMP DEBUG ===")
		print("Zoom: ", zoom)
		print("Visible world size: ", visible_world_size)
		print("View half size: ", view_half_width, ", ", view_half_height)
		print("Map half size: ", map_half_width, ", ", map_half_height)
		print("Max offset (with epsilon): ", max_offset_x, ", ", max_offset_y)
		print("Current position: ", position)
		print("At min zoom? ", zoom.x <= zoom_min.x + 0.001)
		print("==================")
	
	# Clamp position to stay within these bounds
	position.x = clamp(position.x, -max_offset_x, max_offset_x)
	position.y = clamp(position.y, -max_offset_y, max_offset_y)

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
