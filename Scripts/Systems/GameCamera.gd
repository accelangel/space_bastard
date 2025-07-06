# Debug version of GameCamera.gd with enhanced logging
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
	
	# Debug: List all available input actions
	print("=== DEBUG: Available input actions ===")
	for action in InputMap.get_actions():
		print("Action: ", action)

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
	# DEBUG: Add more comprehensive input detection
	if Input.is_action_just_pressed("select_ship"):
		print("=== DEBUG: select_ship action detected! ===")
		handle_mouse_click()
	
	# DEBUG: Also try detecting raw mouse input
	if Input.is_action_just_pressed("select_ship"):
		print("=== DEBUG: Left mouse button pressed! ===")
		var mouse_pos = get_global_mouse_position()
		print("Mouse world position: ", mouse_pos)
		handle_mouse_click()
	
	# Stop following on escape key
	if Input.is_action_just_pressed("ui_cancel"):
		if following_ship:
			stop_following_ship()

func handle_mouse_click():
	print("=== DEBUG: handle_mouse_click() called ===")
	
	var current_time_float = Time.get_time_dict_from_system()["hour"] * 3600.0 + Time.get_time_dict_from_system()["minute"] * 60.0 + Time.get_time_dict_from_system()["second"]
	var current_mouse_pos = get_viewport().get_mouse_position()
	
	print("Current time: ", current_time_float)
	print("Current mouse pos: ", current_mouse_pos)
	print("Last click time: ", last_click_time)
	print("Last click pos: ", last_click_position)
	
	# Check if this is a double-click
	var time_since_last_click = current_time_float - last_click_time
	var distance_from_last_click = current_mouse_pos.distance_to(last_click_position)
	
	print("Time since last click: ", time_since_last_click)
	print("Distance from last click: ", distance_from_last_click)
	
	if time_since_last_click <= double_click_threshold and distance_from_last_click <= click_position_threshold:
		# This is a double-click!
		print("=== DEBUG: Double-click detected! ===")
		select_ship_at_mouse()
	else:
		print("=== DEBUG: Single click (not double-click) ===")
		# For debugging, let's also try selecting on single click
		select_ship_at_mouse()
	
	# Update last click info
	last_click_time = current_time_float
	last_click_position = current_mouse_pos

func select_ship_at_mouse():
	print("=== DEBUG: select_ship_at_mouse() called ===")
	
	var mouse_world_pos = get_global_mouse_position()
	print("Mouse world position: ", mouse_world_pos)
	
	var space_state = get_world_2d().direct_space_state
	
	# Create a point query
	var query = PhysicsPointQueryParameters2D.new()
	query.position = mouse_world_pos
	query.collision_mask = 1  # Assuming ships are on collision layer 1
	
	var results = space_state.intersect_point(query)
	print("Physics query results count: ", results.size())
	
	# Look for ships and torpedoes in the results
	for i in range(results.size()):
		var result = results[i]
		var body = result.collider
		print("Result ", i, ": ", body.name, " (", body.get_class(), ")")
		print("  - Groups: ", body.get_groups())
		print("  - Has get_velocity_mps: ", body.has_method("get_velocity_mps"))
		
		if body.is_in_group("enemy_ships") or body.is_in_group("player_ships") or body.is_in_group("torpedoes") or body.has_method("get_velocity_mps"):
			print("=== DEBUG: Found valid ship/torpedo to follow! ===")
			start_following_ship(body)
			print("Now following: ", body.name)
			return
	
	print("=== DEBUG: No valid ships found at mouse position ===")
	
	# If no ship found, stop following current ship
	if following_ship:
		stop_following_ship()

func start_following_ship(ship: Node2D):
	print("=== DEBUG: start_following_ship() called for: ", ship.name, " ===")
	following_ship = ship
	follow_offset = Vector2.ZERO
	was_following = true
	
	# Show selection indicator
	if selection_indicator:
		selection_indicator.visible = true
		selection_indicator.global_position = ship.global_position
		print("Selection indicator made visible and positioned")
	else:
		print("WARNING: selection_indicator is null!")
	
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
	print("=== DEBUG: Creating selection indicator ===")
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
	
	print("Selection indicator created successfully")

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
