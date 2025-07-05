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

# Ship following variables
var following_ship: Node2D = null
var follow_smoothing: float = 8.0
var follow_offset: Vector2 = Vector2.ZERO
var was_following: bool = false

# Double-click detection
var last_click_time: float = 0.0
var double_click_threshold: float = 0.5  # Maximum time between clicks for double-click
var last_click_position: Vector2 = Vector2.ZERO
var click_position_threshold: float = 20.0  # Maximum pixel distance for double-click

# UI feedback
var selection_indicator: Node2D = null

func _ready():
	zoomTarget = zoom
	zoom_min = calculate_min_zoom()
	print("Map size: ", map_size)
	print("Viewport size: ", get_viewport_rect().size)
	print("Calculated min zoom: ", zoom_min)
	print("Current zoom: ", zoom)
	print("Zoom target: ", zoomTarget)
	
	# Create selection indicator
	create_selection_indicator()

func _process(delta):
	Zoom(delta)
	Pan(delta)
	ClickAndDrag()
	FollowShip(delta)
	HandleShipSelection()

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
		
		var _old_target = zoomTarget
		zoomTarget *= zoom_factor
		zoomTarget = clamp(zoomTarget, zoom_min, zoom_max)
	
	# Smooth interpolation toward target zoom
	if zoom.distance_to(zoomTarget) > 0.001:
		var mouse_world_before = zoom_start_mouse_pos
		zoom = zoom.slerp(zoomTarget, zoomSpeed * delta)
		
		var viewport_center = Vector2(get_viewport().size) / 2
		var mouse_world_after = position + (zoom_start_screen_pos - viewport_center) / zoom
		
		# Only apply zoom offset if not following a ship
		if not following_ship:
			position += mouse_world_before - mouse_world_after

func Pan(delta):
	# Don't allow manual panning while following a ship
	if following_ship:
		return
		
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
		# Don't start dragging if we're following a ship
		if following_ship:
			# Stop following when trying to pan manually
			stop_following_ship()
			return
			
		dragStartMousePos = get_viewport().get_mouse_position()
		dragStartCameraPos = position
		isDragging = true
	
	if isDragging and Input.is_action_just_released("camera_pan"):
		isDragging = false
	
	if isDragging:
		var moveVector = get_viewport().get_mouse_position() - dragStartMousePos
		position = dragStartCameraPos - moveVector * (1 / zoom.x)

func HandleShipSelection():
	# Handle ship selection on double-click
	if Input.is_action_just_pressed("ui_accept"):
		handle_mouse_click()
	
	# Stop following on escape key
	if Input.is_action_just_pressed("ui_cancel"):
		if following_ship:
			stop_following_ship()

func handle_mouse_click():
	var current_time = Time.get_time_dict_from_system()
	var current_time_float = current_time.hour * 3600 + current_time.minute * 60 + current_time.second + current_time.microsecond / 1000000.0
	var current_mouse_pos = get_viewport().get_mouse_position()
	
	# Check if this is a double-click
	var time_since_last_click = current_time_float - last_click_time
	var distance_from_last_click = current_mouse_pos.distance_to(last_click_position)
	
	if time_since_last_click <= double_click_threshold and distance_from_last_click <= click_position_threshold:
		# This is a double-click!
		select_ship_at_mouse()
	
	# Update last click info
	last_click_time = current_time_float
	last_click_position = current_mouse_pos

func select_ship_at_mouse():
	var mouse_world_pos = get_global_mouse_position()
	var space_state = get_world_2d().direct_space_state
	
	# Create a point query
	var query = PhysicsPointQueryParameters2D.new()
	query.position = mouse_world_pos
	query.collision_mask = 1  # Assuming ships are on collision layer 1
	
	var results = space_state.intersect_point(query)
	
	# Look for ships in the results
	for result in results:
		var body = result.collider
		if body.is_in_group("enemy_ships") or body.is_in_group("player_ships") or body.has_method("get_velocity_mps"):
			start_following_ship(body)
			print("Now following: ", body.name)
			return
	
	# If no ship found, stop following current ship
	if following_ship:
		stop_following_ship()

func start_following_ship(ship: Node2D):
	following_ship = ship
	follow_offset = Vector2.ZERO
	was_following = true
	
	# Show selection indicator
	if selection_indicator:
		selection_indicator.visible = true
		selection_indicator.global_position = ship.global_position
	
	print("Camera now following: ", ship.name)

func stop_following_ship():
	if following_ship:
		print("Stopped following: ", following_ship.name)
	following_ship = null
	was_following = false
	
	# Hide selection indicator
	if selection_indicator:
		selection_indicator.visible = false

func FollowShip(delta):
	if not following_ship:
		return
	
	# Check if the ship still exists
	if not is_instance_valid(following_ship):
		stop_following_ship()
		return
	
	# Calculate target position
	var target_pos = following_ship.global_position + follow_offset
	
	# Smooth follow
	var distance = position.distance_to(target_pos)
	if distance > 1.0:  # Only move if we're far enough away
		position = position.lerp(target_pos, follow_smoothing * delta)
	
	# Update selection indicator
	if selection_indicator and selection_indicator.visible:
		selection_indicator.global_position = following_ship.global_position

func create_selection_indicator():
	selection_indicator = Node2D.new()
	selection_indicator.name = "SelectionIndicator"
	selection_indicator.visible = false
	get_tree().current_scene.add_child(selection_indicator)
	
	# Create a simple circle indicator
	var line = Line2D.new()
	line.width = 3.0
	line.default_color = Color.CYAN
	line.z_index = 10
	
	# Create circle points
	var points = []
	var radius = 200.0
	var segments = 32
	for i in range(segments + 1):
		var angle = i * 2 * PI / segments
		points.append(Vector2(cos(angle), sin(angle)) * radius)
	
	line.points = PackedVector2Array(points)
	selection_indicator.add_child(line)
	
	# Add pulsing animation
	var tween = create_tween()
	tween.set_loops()
	tween.tween_method(update_indicator_scale, 0.8, 1.2, 1.0)
	tween.tween_method(update_indicator_scale, 1.2, 0.8, 1.0)

func update_indicator_scale(scale_value: float):
	if selection_indicator and selection_indicator.visible:
		selection_indicator.scale = Vector2(scale_value, scale_value)

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

# Public methods for external control
func set_follow_target(ship: Node2D):
	start_following_ship(ship)

func get_following_ship() -> Node2D:
	return following_ship

func set_follow_smoothing(smoothing: float):
	follow_smoothing = smoothing

func set_follow_offset(new_offset: Vector2):
	follow_offset = new_offset
