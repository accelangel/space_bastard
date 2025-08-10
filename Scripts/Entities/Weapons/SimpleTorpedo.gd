# Scripts/Entities/Weapons/SimpleTorpedo.gd
extends Area2D

# Core parameters
@export var acceleration: float = 980.0       # 100G forward thrust
@export var max_turn_rate: float = 240.0      # degrees/second

# Proportional Navigation for curve following
@export var navigation_constant: float = 4.0  # N value for PN
@export var lead_time_factor: float = 1.5     # How far ahead to predict intercept

# Trajectory parameters
@export var curve_points: int = 50            # Points on Bezier curve
@export var look_ahead_points: int = 5        # How many points ahead to aim for
@export var terminal_range_km: float = 500.0  # When to switch to terminal guidance

# Debug settings
@export var debug_output: bool = true
@export var debug_curve: bool = true
@export var debug_interval: float = 0.5

# Torpedo identity
var torpedo_id: String = ""
var faction: String = "friendly"
var target_node: Node2D = null

# Physics state
var velocity_mps: Vector2 = Vector2.ZERO
var is_alive: bool = true
var marked_for_death: bool = false

# Trajectory state
var bezier_points: Array = []  # The Bezier curve points
var current_curve_index: int = 0
var intercept_point: Vector2 = Vector2.ZERO
var last_target_pos: Vector2 = Vector2.ZERO

# PN state for following curve
var last_los_angle: float = 0.0

# Visual elements
var trajectory_line: Line2D = null

# Debug tracking
var last_debug_print: float = 0.0

func _ready():
	Engine.max_fps = 60
	
	torpedo_id = "torp_%d" % [get_instance_id()]
	
	add_to_group("torpedoes")
	add_to_group("combat_entities")
	
	set_meta("torpedo_id", torpedo_id)
	set_meta("faction", faction)
	set_meta("entity_type", "torpedo")
	
	area_entered.connect(_on_area_entered)
	
	var sprite = get_node_or_null("AnimatedSprite2D")
	if sprite:
		sprite.play()
	
	# Setup trajectory visualization using existing Line2D
	setup_debug_line()
	
	print("Torpedo %s launched - BEZIER + PN GUIDANCE" % torpedo_id)

func setup_debug_line():
	if debug_curve:
		# Use the existing TrajectoryLine node for visualization
		trajectory_line = get_node_or_null("TrajectoryLine")
		if trajectory_line:
			trajectory_line.width = 2.0
			trajectory_line.default_color = Color.ORANGE
			trajectory_line.antialiased = true
			trajectory_line.z_index = 5
			trajectory_line.top_level = true
		
		# Create a separate line for LOS to target
		var los_line = Line2D.new()
		los_line.name = "LOSLine"
		los_line.width = 1.0
		los_line.default_color = Color.RED
		los_line.antialiased = true
		los_line.z_index = 4
		los_line.top_level = true
		add_child(los_line)

func _physics_process(delta):
	if marked_for_death or not is_alive or not target_node:
		return
	
	if not is_instance_valid(target_node):
		mark_for_destruction("lost_target")
		return
	
	# Update trajectory planning
	update_trajectory()
	
	# Use PN to follow the trajectory
	follow_trajectory_with_pn(delta)
	
	# Always thrust forward
	var thrust_direction = Vector2.from_angle(rotation - PI/2)
	velocity_mps += thrust_direction * acceleration * delta
	
	# Update position
	var velocity_pixels = velocity_mps / WorldSettings.meters_per_pixel
	global_position += velocity_pixels * delta
	
	# Update visualization
	if debug_curve and trajectory_line:
		update_trajectory_visualization()
	
	# Debug output
	if debug_output:
		update_debug_output()
	
	check_world_bounds()

func update_trajectory():
	"""Calculate intercept point and generate Bezier curve"""
	if not target_node or not is_instance_valid(target_node):
		return
	
	var target_pos = target_node.global_position
	var target_velocity = Vector2.ZERO
	if target_node.has_method("get_velocity_mps"):
		target_velocity = target_node.get_velocity_mps()
	
	# Calculate intercept point with better prediction
	var to_target = target_pos - global_position
	var distance_m = to_target.length() * WorldSettings.meters_per_pixel
	
	# Better time-to-intercept calculation
	var our_speed = velocity_mps.length()
	var closing_speed = max(our_speed, 500.0)  # Min 500 m/s for calculation
	
	# Use iterative refinement for intercept calculation
	var time_to_intercept = distance_m / closing_speed
	for i in range(3):  # 3 iterations for accuracy
		var predicted_pos = target_pos + (target_velocity / WorldSettings.meters_per_pixel) * time_to_intercept
		var new_distance = global_position.distance_to(predicted_pos) * WorldSettings.meters_per_pixel
		time_to_intercept = new_distance / closing_speed
	
	# Apply lead factor
	time_to_intercept *= lead_time_factor
	
	# Predict where target will be
	var target_velocity_pixels = target_velocity / WorldSettings.meters_per_pixel
	intercept_point = target_pos + target_velocity_pixels * time_to_intercept
	
	# Only regenerate curve if:
	# 1. We don't have one
	# 2. Target moved significantly (500 pixels, not 100)
	# 3. We're getting close and need precision
	var should_regenerate = false
	if bezier_points.is_empty():
		should_regenerate = true
	elif target_pos.distance_to(last_target_pos) > 500:
		should_regenerate = true
	elif distance_m < 1000000 and current_curve_index > curve_points * 0.8:  # Near end of curve and close
		should_regenerate = true
	
	if should_regenerate:
		generate_bezier_curve()
		last_target_pos = target_pos

func generate_bezier_curve():
	"""Create Bezier curve from current position/velocity to intercept"""
	bezier_points.clear()
	
	var p0 = global_position
	var p3 = intercept_point
	
	# Direct vector to intercept
	var to_intercept = p3 - p0
	var distance = to_intercept.length()
	
	# Get current velocity in pixels
	var velocity_pixels = velocity_mps / WorldSettings.meters_per_pixel
	
	var p1: Vector2
	var p2: Vector2
	
	if velocity_pixels.length() > 10:
		# We have velocity - use it for initial control point
		# This ensures smooth transition from current trajectory
		p1 = p0 + velocity_pixels.normalized() * (distance * 0.33)
	else:
		# No velocity yet - point control point toward target
		p1 = p0 + to_intercept * 0.33
	
	# P2: Pull toward intercept for smooth arrival
	p2 = p0 + to_intercept * 0.67
	
	# Generate curve points
	for i in range(curve_points + 1):
		var t = float(i) / float(curve_points)
		var point = calculate_bezier_point(p0, p1, p2, p3, t)
		bezier_points.append(point)
	
	# Debug: Print curve info
	if debug_output:
		var curve_start_angle = rad_to_deg((bezier_points[1] - bezier_points[0]).angle())
		var target_angle = rad_to_deg(to_intercept.angle())
		print("Curve generated: Start angle: %.1f°, Target angle: %.1f°, Distance: %.1f km" % 
			[curve_start_angle, target_angle, distance * WorldSettings.meters_per_pixel / 1000.0])

func calculate_bezier_point(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, t: float) -> Vector2:
	var u = 1.0 - t
	var tt = t * t
	var uu = u * u
	var uuu = uu * u
	var ttt = tt * t
	
	return uuu * p0 + 3 * uu * t * p1 + 3 * u * tt * p2 + ttt * p3

func follow_trajectory_with_pn(delta):
	"""Use Proportional Navigation to follow the Bezier curve"""
	
	# Safety check
	if not target_node or not is_instance_valid(target_node):
		return
	
	if bezier_points.is_empty():
		# No curve yet - just point at target
		var to_target = target_node.global_position - global_position
		var desired_angle = to_target.angle() + PI/2
		var angle_error = atan2(sin(desired_angle - rotation), cos(desired_angle - rotation))
		var turn_rate = clamp(angle_error * 3.0, -deg_to_rad(max_turn_rate), deg_to_rad(max_turn_rate))
		rotation += turn_rate * delta
		return
	
	# Check distance for terminal guidance
	var distance_to_target = global_position.distance_to(target_node.global_position) * WorldSettings.meters_per_pixel
	
	# AGGRESSIVE TERMINAL GUIDANCE - different phases based on distance
	if distance_to_target < terminal_range_km * 1000:  # Within terminal range
		var to_target = target_node.global_position - global_position
		var los_angle = to_target.angle()
		
		# Calculate LOS rate
		var los_rate = 0.0
		if last_los_angle != 0.0:
			var angle_diff = atan2(sin(los_angle - last_los_angle), cos(los_angle - last_los_angle))
			los_rate = angle_diff / delta
		last_los_angle = los_angle
		
		# Adaptive PN constant based on distance
		var terminal_n = navigation_constant
		var heading_gain = 2.0
		
		if distance_to_target < 100000:  # Within 100km - CRITICAL
			terminal_n = navigation_constant * 3.0  # Triple PN gain
			heading_gain = 10.0  # VERY aggressive heading correction
		elif distance_to_target < 200000:  # Within 200km - URGENT  
			terminal_n = navigation_constant * 2.0
			heading_gain = 6.0
		else:  # 200-500km - TERMINAL
			terminal_n = navigation_constant * 1.5
			heading_gain = 4.0
		
		# PN command
		var commanded_turn_rate = terminal_n * los_rate
		
		# Heading correction
		var current_heading = rotation - PI/2
		var heading_error = atan2(sin(los_angle - current_heading), cos(los_angle - current_heading))
		
		# If we're pointing way off at close range, use pure pursuit
		if distance_to_target < 100000 and abs(heading_error) > deg_to_rad(45):
			# Emergency maneuver - pure pursuit at max turn rate
			commanded_turn_rate = sign(heading_error) * deg_to_rad(max_turn_rate)
		else:
			# Normal PN + heading correction
			commanded_turn_rate += heading_error * heading_gain
		
		# Apply turn
		commanded_turn_rate = clamp(commanded_turn_rate, -deg_to_rad(max_turn_rate), deg_to_rad(max_turn_rate))
		rotation += commanded_turn_rate * delta
		return
	
	# CRUISE PHASE - Follow the Bezier curve
	# Find closest point on curve
	var min_dist = INF
	var closest_idx = 0
	for i in range(bezier_points.size()):
		var dist = global_position.distance_squared_to(bezier_points[i])
		if dist < min_dist:
			min_dist = dist
			closest_idx = i
	
	# Update current index
	current_curve_index = closest_idx
	
	# Get target point (a few points ahead on the curve)
	var target_idx = min(closest_idx + look_ahead_points, bezier_points.size() - 1)
	var target_point = bezier_points[target_idx]
	
	# Calculate LOS to target point
	var los_vector = target_point - global_position
	var los_angle = los_vector.angle()
	
	# Calculate LOS rate for PN
	var los_rate = 0.0
	if last_los_angle != 0.0:
		var angle_diff = atan2(sin(los_angle - last_los_angle), cos(los_angle - last_los_angle))
		los_rate = angle_diff / delta
	last_los_angle = los_angle
	
	# Proportional Navigation law
	var commanded_turn_rate = navigation_constant * los_rate
	
	# Add heading correction
	var current_heading = rotation - PI/2
	var heading_error = atan2(sin(los_angle - current_heading), cos(los_angle - current_heading))
	commanded_turn_rate += heading_error * 2.0
	
	# Apply turn rate limits
	commanded_turn_rate = clamp(commanded_turn_rate, -deg_to_rad(max_turn_rate), deg_to_rad(max_turn_rate))
	
	# Apply rotation
	rotation += commanded_turn_rate * delta

func update_trajectory_visualization():
	if not trajectory_line:
		return
	
	# Get camera for line width scaling
	var cam = get_viewport().get_camera_2d()
	var scale_factor = 1.0
	if cam:
		scale_factor = 1.0 / cam.zoom.x
	
	# Update LOS line (red, half width)
	var los_line = get_node_or_null("LOSLine")
	if los_line and target_node and is_instance_valid(target_node):
		los_line.clear_points()
		los_line.add_point(global_position)
		los_line.add_point(target_node.global_position)
		los_line.width = 1.0 * scale_factor  # Half the width of trajectory
		los_line.default_color = Color.RED
	
	# Draw the Bezier curve properly (only ahead of torpedo)
	trajectory_line.clear_points()
	trajectory_line.width = 2.0 * scale_factor
	trajectory_line.default_color = Color.ORANGE
	
	if bezier_points.is_empty():
		return
	
	# Find the closest point index
	var closest_idx = current_curve_index
	
	# Draw from current position to the end of the curve
	# First point is torpedo's current position for smooth connection
	trajectory_line.add_point(global_position)
	
	# Then add all remaining bezier points
	for i in range(closest_idx + 1, bezier_points.size()):
		trajectory_line.add_point(bezier_points[i])

func update_debug_output():
	var current_time = Time.get_ticks_msec() / 1000.0
	if current_time - last_debug_print < debug_interval:
		return
	last_debug_print = current_time
	
	if not target_node or not is_instance_valid(target_node):
		return
	
	var speed_kms = velocity_mps.length() / 1000.0
	var range_km = global_position.distance_to(target_node.global_position) * WorldSettings.meters_per_pixel / 1000.0
	var intercept_range_km = global_position.distance_to(intercept_point) * WorldSettings.meters_per_pixel / 1000.0
	
	# Calculate progress along curve
	var curve_progress = 0.0
	if not bezier_points.is_empty():
		curve_progress = float(current_curve_index) / float(curve_points) * 100.0
	
	# Calculate heading error to intercept
	var to_intercept = intercept_point - global_position
	var desired_heading = to_intercept.angle()
	var current_heading = rotation - PI/2
	var heading_error = rad_to_deg(atan2(sin(desired_heading - current_heading), cos(desired_heading - current_heading)))
	
	# Show if in terminal phase
	var phase = "TERM" if range_km < terminal_range_km else "CRUISE"
	
	print("Torpedo %s [%s]: %.1f km/s | Target: %.1f km | Intercept: %.1f km | Curve: %.0f%% | Error: %.1f°" % 
		[torpedo_id, phase, speed_kms, range_km, intercept_range_km, curve_progress, heading_error])

func check_world_bounds():
	var half_size = WorldSettings.map_size_pixels / 2
	if abs(global_position.x) > half_size.x or abs(global_position.y) > half_size.y:
		mark_for_destruction("out_of_bounds")

func _on_area_entered(area: Area2D):
	if marked_for_death or not is_alive:
		return
	
	if area.is_in_group("ships"):
		if area.get("faction") == faction:
			return
		
		print("Torpedo %s hit target!" % torpedo_id)
		
		if area.has_method("mark_for_destruction"):
			area.mark_for_destruction("torpedo_impact")
		
		mark_for_destruction("target_impact")

func mark_for_destruction(reason: String):
	if marked_for_death:
		return
	
	marked_for_death = true
	is_alive = false
	
	print("Torpedo %s destroyed: %s" % [torpedo_id, reason])
	
	# Hide both visualization lines
	if trajectory_line:
		trajectory_line.visible = false
	var los_line = get_node_or_null("LOSLine")
	if los_line:
		los_line.visible = false
	
	set_physics_process(false)
	var collision = get_node_or_null("CollisionShape2D")
	if collision:
		collision.disabled = true
	
	queue_free()

# Public interface
func set_target(target: Node2D):
	target_node = target

func set_launcher(launcher_ship: Node2D):
	if "faction" in launcher_ship:
		faction = launcher_ship.faction

func get_velocity_mps() -> Vector2:
	return velocity_mps

# Compatibility
func set_launch_side(_side: int):
	pass

func set_flight_plan(_plan: String, _data: Dictionary = {}):
	pass
