# Enhanced GameCamera.gd - With Floating Origin Support
extends Camera2D

# Map configuration
var map_size = Vector2(4000000, 2250000)
var zoom_min: Vector2 = Vector2(0.00048, 0.00048)
var zoom_max: Vector2 = Vector2(10.0, 10.0)

# TRUE POSITION TRACKING (for floating origin)
var true_position: Vector2 = Vector2.ZERO  # Camera's true world position
var visual_limits_enabled: bool = false    # Disable limits during reorigin

# Zoom system variables
var zoom_start_mouse_pos = Vector2.ZERO
var zoom_start_screen_pos = Vector2.ZERO
@export var zoomSpeed: float = 11
var zoomTarget: Vector2

# Click and drag variables
var dragStartMousePos = Vector2.ZERO
var dragStartCameraPos = Vector2.ZERO
var dragStartTruePos = Vector2.ZERO  # True position at drag start
var isDragging: bool = false

# Ship following variables
var following_ship: Node2D = null
var follow_smoothing: float = 12.0
var follow_offset: Vector2 = Vector2.ZERO
var follow_deadzone: float = 0.1

# Relative panning while following
var relative_pan_offset: Vector2 = Vector2.ZERO
var is_relative_panning: bool = false
var relative_pan_start_mouse: Vector2 = Vector2.ZERO
var relative_pan_start_offset: Vector2 = Vector2.ZERO

# UI feedback
var selection_indicator: Node2D = null

func _ready():
	# Add to group for identification
	add_to_group("game_camera")
	
	FloatingOrigin.origin_shifted.connect(_on_origin_shifted)
	
	zoomTarget = zoom
	zoom_min = calculate_min_zoom()
	
	print("GameCamera initialized with Floating Origin support")
	print("Map size: ", map_size)
	print("Viewport size: ", get_viewport_rect().size)
	print("Min zoom: ", zoom_min)
	
	# Create selection indicator
	create_selection_indicator()
	
	# Start following the player ship
	call_deferred("focus_on_player_ship")

func _on_origin_shifted(shift_amount: Vector2):
	"""Handle floating origin shifts"""
	# Our visual position has been shifted by FloatingOrigin
	# Update our true position to compensate
	true_position -= shift_amount
	
	# Update drag positions if dragging
	if isDragging:
		dragStartCameraPos += shift_amount

func _process(delta):
	handle_zoom(delta)
	handle_pan(delta)
	handle_click_and_drag()
	handle_ship_selection()
	follow_ship(delta)
	
	# Update true position based on visual position
	true_position = FloatingOrigin.visual_to_true(global_position)

func get_view_stats() -> String:
	var viewport_size = get_viewport_rect().size
	var world_visible_pixels = viewport_size / zoom
	var world_visible_meters = world_visible_pixels * WorldSettings.meters_per_pixel
	var world_visible_km = world_visible_meters / 1000.0
	
	var map_size_km = map_size * WorldSettings.meters_per_pixel / 1000.0
	
	var coverage_x = (world_visible_km.x / map_size_km.x) * 100.0
	var coverage_y = (world_visible_km.y / map_size_km.y) * 100.0
	
	var true_pos_km = true_position * WorldSettings.meters_per_pixel / 1000.0
	
	return "View: %.0f × %.0f km\nTrue Pos: (%.0f, %.0f) km\nVisual: (%.0f, %.0f) px\nCoverage: %.1f%% × %.1f%%\nZoom: %.6f" % [
		world_visible_km.x, world_visible_km.y,
		true_pos_km.x, true_pos_km.y,
		global_position.x, global_position.y,
		coverage_x, coverage_y,
		zoom.x
	]

func handle_zoom(delta):
	var scroll = 0
	
	# Check if mouse is over any PiP camera
	var mouse_pos = get_viewport().get_mouse_position()
	var is_mouse_over_pip = false
	
	var pip_cameras = get_tree().get_nodes_in_group("pip_cameras")
	for pip in pip_cameras:
		if pip is Control and pip.visible:
			var pip_rect = Rect2(pip.global_position, pip.size)
			if pip_rect.has_point(mouse_pos):
				is_mouse_over_pip = true
				break
	
	if not is_mouse_over_pip:
		if Input.is_action_just_pressed("camera_zoom_in"):
			scroll = 1
		elif Input.is_action_just_pressed("camera_zoom_out"):
			scroll = -1
	
	if scroll != 0:
		var zoom_factor = 1.1 ** scroll
		zoom_start_mouse_pos = get_global_mouse_position()
		zoom_start_screen_pos = Vector2(get_viewport().get_mouse_position())
		
		zoomTarget *= zoom_factor
		zoomTarget = clamp(zoomTarget, zoom_min, zoom_max)
	
	# Direct assignment at extreme zoom levels to avoid precision issues
	if zoomTarget.x < 0.001 or zoomTarget.x > 1000:
		zoom = zoomTarget
	elif abs(zoom.x - zoomTarget.x) > 0.000001:
		zoom = zoom.slerp(zoomTarget, zoomSpeed * delta)
	else:
		zoom = zoomTarget

func handle_pan(delta):
	if following_ship and not is_relative_panning:
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
	
	if following_ship:
		relative_pan_offset += moveAmount * delta * 1000 * (1 / zoom.x)
	else:
		# Move camera and update true position
		var movement = moveAmount * delta * 1000 * (1 / zoom.x)
		position += movement
		true_position += movement
		
		# Apply map limits to true position
		apply_position_limits()

func apply_position_limits():
	"""Apply map boundaries to true position and sync visual position"""
	if visual_limits_enabled:
		return  # Skip during reorigin
	
	var viewport_size = get_viewport_rect().size
	var view_half_width = (viewport_size.x / 2) / zoom.x
	var view_half_height = (viewport_size.y / 2) / zoom.x
	
	# Clamp true position
	true_position.x = clamp(true_position.x, 
		-map_size.x/2 + view_half_width, 
		map_size.x/2 - view_half_width)
	true_position.y = clamp(true_position.y, 
		-map_size.y/2 + view_half_height, 
		map_size.y/2 - view_half_height)
	
	# Update visual position from true position
	global_position = FloatingOrigin.true_to_visual(true_position)

func handle_click_and_drag():
	if !isDragging and Input.is_action_just_pressed("camera_pan"):
		if following_ship:
			start_relative_panning()
		else:
			dragStartMousePos = get_viewport().get_mouse_position()
			dragStartCameraPos = position
			dragStartTruePos = true_position
			isDragging = true
	
	if isDragging and Input.is_action_just_released("camera_pan"):
		isDragging = false
	
	if is_relative_panning and Input.is_action_just_released("camera_pan"):
		stop_relative_panning()
	
	if isDragging:
		var moveVector = get_viewport().get_mouse_position() - dragStartMousePos
		var movement = moveVector * (1 / zoom.x)
		position = dragStartCameraPos - movement
		true_position = dragStartTruePos - movement
		apply_position_limits()
	
	if is_relative_panning and following_ship:
		update_relative_panning()

func start_relative_panning():
	is_relative_panning = true
	relative_pan_start_mouse = get_viewport().get_mouse_position()
	relative_pan_start_offset = relative_pan_offset

func stop_relative_panning():
	is_relative_panning = false

func update_relative_panning():
	if not following_ship:
		return
	
	var mouse_delta = get_viewport().get_mouse_position() - relative_pan_start_mouse
	var world_delta = mouse_delta * (1 / zoom.x)
	world_delta.x = -world_delta.x
	world_delta.y = -world_delta.y
	
	relative_pan_offset = relative_pan_start_offset + world_delta

func handle_ship_selection():
	if Input.is_action_just_pressed("select_ship"):
		select_ship_at_mouse()
	
	if Input.is_action_just_pressed("ui_cancel"):
		if following_ship:
			stop_following_ship()

func select_ship_at_mouse():
	var mouse_world_pos = get_global_mouse_position()
	var found_ship = find_ship_at_position(mouse_world_pos)
	
	if found_ship:
		start_following_ship(found_ship)
	else:
		if following_ship:
			stop_following_ship()

func find_ship_at_position(world_pos: Vector2) -> Node2D:
	var space_state = get_world_2d().direct_space_state
	var query = PhysicsPointQueryParameters2D.new()
	query.position = world_pos
	query.collision_mask = 0xFFFFFFFF
	query.collide_with_areas = true
	query.collide_with_bodies = true
	
	var results = space_state.intersect_point(query)
	
	for result in results:
		var body = result.collider
		if is_selectable_object(body):
			return body
	
	var base_radius = 500.0
	var search_radius = base_radius / zoom.x
	var all_selectables = get_all_selectable_objects()
	
	for obj in all_selectables:
		if obj.global_position.distance_to(world_pos) <= search_radius:
			return obj
	
	return null

func is_selectable_object(obj: Node) -> bool:
	return (obj.is_in_group("enemy_ships") or 
			obj.is_in_group("player_ships") or 
			obj.is_in_group("torpedoes") or 
			obj.has_method("get_velocity_mps"))

func get_all_selectable_objects() -> Array:
	var objects = []
	objects.append_array(get_tree().get_nodes_in_group("enemy_ships"))
	objects.append_array(get_tree().get_nodes_in_group("player_ships"))
	objects.append_array(get_tree().get_nodes_in_group("torpedoes"))
	return objects

func start_following_ship(ship: Node2D):
	following_ship = ship
	follow_offset = Vector2.ZERO
	relative_pan_offset = Vector2.ZERO
	
	if selection_indicator:
		selection_indicator.visible = true
		selection_indicator.global_position = ship.global_position

func stop_following_ship():
	following_ship = null
	is_relative_panning = false
	relative_pan_offset = Vector2.ZERO
	
	if selection_indicator:
		selection_indicator.visible = false

func follow_ship(_delta):
	if not following_ship:
		return
	
	if not is_instance_valid(following_ship):
		stop_following_ship()
		return
	
	# Update position (visual)
	position = following_ship.global_position + follow_offset + relative_pan_offset
	
	# Update true position
	true_position = FloatingOrigin.visual_to_true(position)
	
	if selection_indicator and selection_indicator.visible:
		selection_indicator.global_position = following_ship.global_position

func create_selection_indicator():
	selection_indicator = Node2D.new()
	selection_indicator.name = "SelectionIndicator"
	selection_indicator.visible = false
	selection_indicator.add_to_group("selection_indicator")  # Add to group for floating origin
	get_tree().current_scene.add_child(selection_indicator)
	
	var line = Line2D.new()
	line.width = 3.0
	line.default_color = Color.CYAN
	line.z_index = 10
	
	var points = []
	var radius = 150.0
	var segments = 32
	for i in range(segments + 1):
		var angle = i * 2 * PI / segments
		points.append(Vector2(cos(angle), sin(angle)) * radius)
	
	line.points = PackedVector2Array(points)
	selection_indicator.add_child(line)
	
	var tween = create_tween()
	tween.set_loops()
	tween.tween_method(update_indicator_scale, 0.8, 1.2, 1.0)
	tween.tween_method(update_indicator_scale, 1.2, 0.8, 1.0)

func update_indicator_scale(scale_value: float):
	if selection_indicator and selection_indicator.visible:
		selection_indicator.scale = Vector2(scale_value, scale_value)

func calculate_min_zoom():
	var viewport_size = get_viewport_rect().size
	var _zoom_for_width = viewport_size.x / map_size.x
	var _zoom_for_height = viewport_size.y / map_size.y
	
	var clean_zoom = min(_zoom_for_width, _zoom_for_height)
	return Vector2(clean_zoom, clean_zoom)

func focus_on_player_ship():
	var player_ships = get_tree().get_nodes_in_group("player_ships")
	if player_ships.size() > 0:
		var player_ship = player_ships[0]
		start_following_ship(player_ship)
		
		zoom = Vector2(2.0, 2.0)
		zoomTarget = zoom
		
		position = player_ship.global_position
		true_position = FloatingOrigin.visual_to_true(position)
		
		print("Camera focused on player ship at startup")

# Public methods
func set_follow_target(ship: Node2D):
	start_following_ship(ship)

func get_following_ship() -> Node2D:
	return following_ship

func set_follow_smoothing(smoothing: float):
	follow_smoothing = smoothing

func set_follow_offset(new_offset: Vector2):
	follow_offset = new_offset

func reset_relative_pan_offset():
	relative_pan_offset = Vector2.ZERO

func get_relative_pan_offset() -> Vector2:
	return relative_pan_offset

func set_relative_pan_offset(new_offset: Vector2):
	relative_pan_offset = new_offset

func get_true_position() -> Vector2:
	return true_position
