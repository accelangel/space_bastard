# Enhanced GameCamera.gd - FIXED ZOOM CALCULATION
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
var follow_smoothing: float = 12.0  # Increased for smoother tracking
var follow_offset: Vector2 = Vector2.ZERO
var follow_deadzone: float = 0.1    # Minimum distance before we start following

# NEW: Relative panning while following
var relative_pan_offset: Vector2 = Vector2.ZERO
var is_relative_panning: bool = false
var relative_pan_start_mouse: Vector2 = Vector2.ZERO
var relative_pan_start_offset: Vector2 = Vector2.ZERO

# UI feedback
var selection_indicator: Node2D = null

func _ready():
	zoomTarget = zoom
	zoom_min = calculate_min_zoom()
	print("GameCamera initialized")
	print("Map size: ", map_size)
	print("Viewport size: ", get_viewport_rect().size)
	print("Min zoom: ", zoom_min)
	
	# Create selection indicator
	create_selection_indicator()

func _process(delta):
	handle_zoom(delta)
	handle_pan(delta)
	handle_click_and_drag()
	handle_ship_selection()
	follow_ship(delta)

func _input(event):
	# Add debug key to force end battle and print system state
	if event.is_action_pressed("ui_cancel") and Input.is_key_pressed(KEY_CTRL):
		print_full_system_state()
		
		var battle_manager = get_node_or_null("../BattleManager")
		if not battle_manager:
			battle_manager = get_tree().get_first_node_in_group("battle_managers")
		
		if battle_manager and battle_manager.has_method("force_end_battle"):
			battle_manager.force_end_battle()

func handle_zoom(delta):
	var scroll = 0
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
	
	# Smooth interpolation toward target zoom
	if zoom.distance_to(zoomTarget) > 0.001:
		var mouse_world_before = zoom_start_mouse_pos
		zoom = zoom.slerp(zoomTarget, zoomSpeed * delta)
		
		var viewport_center = Vector2(get_viewport().size) / 2
		var mouse_world_after = position + (zoom_start_screen_pos - viewport_center) / zoom
		
		# Only apply zoom offset if not following a ship
		if not following_ship:
			position += mouse_world_before - mouse_world_after

func handle_pan(delta):
	# Don't allow manual panning while following a ship (unless it's relative panning)
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
		# When following a ship, keyboard movement adjusts the relative offset
		relative_pan_offset += moveAmount * delta * 1000 * (1 / zoom.x)
	else:
		# Normal panning when not following
		position += moveAmount * delta * 1000 * (1 / zoom.x)

func handle_click_and_drag():
	# Start dragging with middle mouse button
	if !isDragging and Input.is_action_just_pressed("camera_pan"):
		if following_ship:
			# Start relative panning while following
			start_relative_panning()
		else:
			# Normal drag panning when not following
			dragStartMousePos = get_viewport().get_mouse_position()
			dragStartCameraPos = position
			isDragging = true
	
	# Stop dragging
	if isDragging and Input.is_action_just_released("camera_pan"):
		isDragging = false
	
	# Stop relative panning
	if is_relative_panning and Input.is_action_just_released("camera_pan"):
		stop_relative_panning()
	
	# Apply drag movement
	if isDragging:
		var moveVector = get_viewport().get_mouse_position() - dragStartMousePos
		position = dragStartCameraPos - moveVector * (1 / zoom.x)
	
	# Apply relative panning while following
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
	# Convert screen space movement to world space offset
	var world_delta = mouse_delta * (1 / zoom.x)
	# Invert both X and Y to match expected panning behavior
	world_delta.x = -world_delta.x
	world_delta.y = -world_delta.y
	
	relative_pan_offset = relative_pan_start_offset + world_delta

func handle_ship_selection():
	# Simple single-click selection
	if Input.is_action_just_pressed("select_ship"):
		select_ship_at_mouse()
	
	# Stop following on escape key
	if Input.is_action_just_pressed("ui_cancel") and not Input.is_key_pressed(KEY_CTRL):
		if following_ship:
			stop_following_ship()

func select_ship_at_mouse():
	var mouse_world_pos = get_global_mouse_position()
	
	# Try to find ships using multiple methods
	var found_ship = find_ship_at_position(mouse_world_pos)
	
	if found_ship:
		start_following_ship(found_ship)
	else:
		# If no ship found, stop following current ship
		if following_ship:
			stop_following_ship()

func find_ship_at_position(world_pos: Vector2) -> Node2D:
	# Method 1: Physics query
	var space_state = get_world_2d().direct_space_state
	var query = PhysicsPointQueryParameters2D.new()
	query.position = world_pos
	query.collision_mask = 0xFFFFFFFF  # Check all collision layers
	query.collide_with_areas = true    # Important for Area2D ships
	query.collide_with_bodies = true
	
	var results = space_state.intersect_point(query)
	
	# Check physics query results first
	for result in results:
		var body = result.collider
		if is_selectable_object(body):
			return body
	
	# Method 2: Radius-based search if physics query fails
	var search_radius = 50.0 / zoom.x  # Adjust search radius based on zoom
	var all_selectables = get_all_selectable_objects()
	
	for obj in all_selectables:
		if obj.global_position.distance_to(world_pos) <= search_radius:
			return obj
	
	return null

func is_selectable_object(obj: Node) -> bool:
	# Check if object is a ship or torpedo that can be followed
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
	# Reset relative pan offset when starting to follow a new ship
	relative_pan_offset = Vector2.ZERO
	
	# Show selection indicator
	if selection_indicator:
		selection_indicator.visible = true
		selection_indicator.global_position = ship.global_position

func stop_following_ship():
	following_ship = null
	
	# Reset relative panning state
	is_relative_panning = false
	relative_pan_offset = Vector2.ZERO
	
	# Hide selection indicator
	if selection_indicator:
		selection_indicator.visible = false

func follow_ship(_delta):
	if not following_ship:
		return
	
	# Check if the ship still exists
	if not is_instance_valid(following_ship):
		stop_following_ship()
		return
	
	# Apply ship position + any relative offset from panning
	position = following_ship.global_position + follow_offset + relative_pan_offset
	
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
	var radius = 150.0
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
	var zoom_for_width = viewport_size.x / map_size.x
	var zoom_for_height = viewport_size.y / map_size.y
	# FIXED: Use the larger of the two to ensure entire map fits, with buffer
	var min_zoom_value = max(zoom_for_width, zoom_for_height) * 1.1
	return Vector2(min_zoom_value, min_zoom_value)

# GLOBAL DEBUG FUNCTION
func print_full_system_state():
	print("\n=== FULL SYSTEM DEBUG STATE ===")
	
	var entity_manager = get_node_or_null("/root/EntityManager")
	if entity_manager:
		print("EntityManager: %d total entities" % entity_manager.entities.size())
		for entity_id in entity_manager.entities:
			var entity = entity_manager.entities[entity_id]
			print("  %s: %s (destroyed: %s, valid: %s)" % [
				entity_id, entity.entity_type, entity.is_destroyed, is_instance_valid(entity.node_ref)
			])
	
	var ships = get_tree().get_nodes_in_group("enemy_ships") + get_tree().get_nodes_in_group("player_ships")
	for ship in ships:
		var sensor = ship.get_node_or_null("SensorSystem")
		if sensor:
			print("Ship %s SensorSystem: %d contacts" % [ship.name, sensor.all_contacts.size()])
		
		var firecontrol = ship.get_node_or_null("FireControlManager")
		if firecontrol:
			print("Ship %s FireControl: %d tracked targets" % [ship.name, firecontrol.tracked_targets.size()])
			for target_id in firecontrol.tracked_targets:
				var target_data = firecontrol.tracked_targets[target_id]
				print("    Target %s: valid=%s, assigned_pdcs=%d" % [
					target_id, is_instance_valid(target_data.node_ref), target_data.assigned_pdcs.size()
				])
	
	print("=== END DEBUG STATE ===\n")

# Public methods for external control
func set_follow_target(ship: Node2D):
	start_following_ship(ship)

func get_following_ship() -> Node2D:
	return following_ship

func set_follow_smoothing(smoothing: float):
	follow_smoothing = smoothing

func set_follow_offset(new_offset: Vector2):
	follow_offset = new_offset

# NEW: Public methods for relative panning control
func reset_relative_pan_offset():
	relative_pan_offset = Vector2.ZERO

func get_relative_pan_offset() -> Vector2:
	return relative_pan_offset

func set_relative_pan_offset(new_offset: Vector2):
	relative_pan_offset = new_offset
