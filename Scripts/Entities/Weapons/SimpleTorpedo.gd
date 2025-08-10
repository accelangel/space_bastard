# Scripts/Entities/Weapons/SimpleTorpedo.gd
extends Area2D

# Core parameters
@export var acceleration: float = 980.0       # 100G forward thrust
@export var max_turn_rate: float = 1080.0     # degrees/second (3 full rotations)

# Proportional Navigation with gain scheduling
@export var navigation_constant_initial: float = 1.0  # N value at launch
@export var navigation_constant_final: float = 50.0  # N value after ramp-up
@export var gain_hold_time: float = 3.0  # Hold initial gain for this long
@export var gain_ramp_time: float = 15.0  # Ramp up over this duration

# Trajectory parameters
@export var curve_strength: float = 0.1       # How much the trajectory curves (0 = straight, 1 = maximum curve)
@export var trajectory_points: int = 50      # Points for visualization
@export var intercept_iterations: int = 10    # Iterations for intercept calculation

# Debug settings
@export var debug_output: bool = true
@export var debug_interval: float = 1.0  # Once per second

# Torpedo identity
var torpedo_id: String = ""
var faction: String = "friendly"
var target_node: Node2D = null

# Physics state
var velocity_mps: Vector2 = Vector2.ZERO
var is_alive: bool = true
var marked_for_death: bool = false

# Trajectory state
var intercept_point: Vector2 = Vector2.ZERO
var trajectory_curve: Array = []  # Points for visualization only
var closest_point_on_curve: Vector2 = Vector2.ZERO
var curve_t: float = 0.0  # Parameter along the curve (0 to 1)

# PN state
var last_los_angle: float = 0.0

# Tracking statistics
var closest_approach_distance: float = INF
var closest_approach_time: float = 0.0
var time_since_launch: float = 0.0

# Collision debugging
var collision_checked: bool = false
var last_distance_logged: float = INF

# Visual elements
var trajectory_line: Line2D = null

# Debug tracking
var last_debug_print: float = 0.0
var initial_gain_logged: bool = false
var max_gain_logged: bool = false
var last_gain_phase: String = "initial"  # "initial", "ramping", "max"

func _ready():
	Engine.max_fps = 60
	
	torpedo_id = "torp_%d" % [get_instance_id()]
	print("  - Initial rotation: %.1f degrees" % rad_to_deg(rotation))
	
	add_to_group("torpedoes")
	add_to_group("combat_entities")
	
	set_meta("torpedo_id", torpedo_id)
	set_meta("faction", faction)
	set_meta("entity_type", "torpedo")
	
	# COLLISION DEBUG: Log initial setup
	print("Torpedo %s launched - PHYSICS-BASED INTERCEPT + PN GUIDANCE" % torpedo_id)
	print("  - Faction: %s" % faction)
	print("  - Groups: %s" % get_groups())
	print("  - Monitoring enabled: %s" % monitoring)
	print("  - Monitorable enabled: %s" % monitorable)
	
	# Check collision shape location - it might be under AnimatedSprite2D
	var collision_shape = get_node_or_null("CollisionShape2D")
	var animated_sprite = get_node_or_null("AnimatedSprite2D")
	if animated_sprite:
		var sprite_collision = animated_sprite.get_node_or_null("CollisionShape2D")
		if sprite_collision:
			print("  - CollisionShape2D found under AnimatedSprite2D")
			collision_shape = sprite_collision
	
	if collision_shape:
		print("  - Collision shape: %s" % collision_shape.shape.get_class())
		print("  - Collision disabled: %s" % collision_shape.disabled)
		# Check shape properties based on type
		if collision_shape.shape is CapsuleShape2D:
			print("  - Capsule radius: %.1f pixels" % collision_shape.shape.radius)
			print("  - Capsule height: %.1f pixels" % collision_shape.shape.height)
		elif collision_shape.shape is CircleShape2D:
			print("  - Circle radius: %.1f pixels" % collision_shape.shape.radius)
		elif collision_shape.shape is RectangleShape2D:
			print("  - Rectangle size: %s pixels" % collision_shape.shape.size)
		# Account for parent scale
		var parent_scale = animated_sprite.scale if animated_sprite else Vector2.ONE
		print("  - Parent scale: %s" % parent_scale)
		print("  - Effective size multiplier: %.3f" % (parent_scale.x if parent_scale.x == parent_scale.y else parent_scale))
	else:
		print("  - WARNING: No CollisionShape2D found!")
	
	# Connect collision signal
	area_entered.connect(_on_area_entered)
	print("  - area_entered signal connected: %s" % area_entered.is_connected(_on_area_entered))
	
	# Log gain scheduling info
	print("  - Gain scheduling: N=%.1f initial, ramping to N=%.1f over %.1f-%.1fs" % 
		[navigation_constant_initial, navigation_constant_final, gain_hold_time, gain_hold_time + gain_ramp_time])
	
	var sprite = get_node_or_null("AnimatedSprite2D")
	if sprite:
		sprite.play()
	
	# Setup trajectory visualization
	setup_trajectory_line()

func setup_trajectory_line():
	# Use the existing TrajectoryLine node for visualization
	trajectory_line = get_node_or_null("TrajectoryLine")
	if trajectory_line:
		trajectory_line.width = 2.0
		trajectory_line.default_color = Color.ORANGE
		trajectory_line.antialiased = true
		trajectory_line.z_index = 5
		trajectory_line.top_level = true

func get_current_navigation_constant() -> float:
	"""Calculate the current navigation constant based on time since launch"""
	if time_since_launch <= gain_hold_time:
		# First 5 seconds: use initial gain
		return navigation_constant_initial
	elif time_since_launch <= gain_hold_time + gain_ramp_time:
		# Next 10 seconds: ramp up from initial to final
		var ramp_progress = (time_since_launch - gain_hold_time) / gain_ramp_time
		return lerp(navigation_constant_initial, navigation_constant_final, ramp_progress)
	else:
		# After 15 seconds: use final gain
		return navigation_constant_final

func _physics_process(delta):
	if marked_for_death or not is_alive or not target_node:
		return
	
	if not is_instance_valid(target_node):
		mark_for_destruction("lost_target")
		return
	
	# Update time tracking
	time_since_launch += delta
	
	# TEMPORARY DEBUG - Remove after testing
	if time_since_launch < 0.1:
		print("Torpedo %s at %.3fs: rotation=%.1f°" % [torpedo_id, time_since_launch, rad_to_deg(rotation)])
	
	# Track closest approach
	update_closest_approach()
	
	# COLLISION DEBUG: Check if we're extremely close
	check_proximity_collision()
	
	# Generate intercept trajectory every frame
	generate_intercept_trajectory()
	
	# Follow the trajectory using PN
	follow_trajectory_with_pn(delta)
	
	# Always thrust forward
	var thrust_direction = Vector2.from_angle(rotation - PI/2)
	velocity_mps += thrust_direction * acceleration * delta
	
	# Update position
	var velocity_pixels = velocity_mps / WorldSettings.meters_per_pixel
	global_position += velocity_pixels * delta
	
	# Update visualization
	if trajectory_line:
		update_trajectory_visualization()
	
	# Debug output
	if debug_output:
		update_debug_output()
	
	check_world_bounds()

func check_proximity_collision():
	"""Debug function to check if we should have hit but didn't"""
	if not target_node or not is_instance_valid(target_node):
		return
	
	var distance = global_position.distance_to(target_node.global_position)
	var distance_meters = distance * WorldSettings.meters_per_pixel
	
	# Log at specific distance thresholds
	if distance_meters < 100.0 and last_distance_logged > 100.0:
		print("COLLISION DEBUG [%s]: Within 100m of target! Distance: %.1f m" % [torpedo_id, distance_meters])
		print("  - Torpedo pos: %s" % global_position)
		print("  - Target pos: %s" % target_node.global_position)
		print("  - Pixel distance: %.1f" % distance)
		
		# Check collision shapes
		var my_collision = get_node_or_null("CollisionShape2D")
		if my_collision:
			print("  - Torpedo collision enabled: %s" % (not my_collision.disabled))
			if my_collision.shape:
				print("  - Torpedo collision shape: %s" % my_collision.shape.get_class())
		
		var target_collision = target_node.get_node_or_null("CollisionShape2D")
		if target_collision:
			print("  - Target collision enabled: %s" % (not target_collision.disabled))
			if target_collision.shape:
				var shape_info = target_collision.shape.get_class()
				if target_collision.shape is CapsuleShape2D:
					shape_info += " (radius: %.1f, height: %.1f)" % [target_collision.shape.radius, target_collision.shape.height]
				elif target_collision.shape is CircleShape2D:
					shape_info += " (radius: %.1f)" % target_collision.shape.radius
				elif target_collision.shape is RectangleShape2D:
					shape_info += " (size: %s)" % target_collision.shape.size
				print("  - Target collision shape: %s" % shape_info)
	
	if distance_meters < 50.0 and last_distance_logged > 50.0:
		print("COLLISION DEBUG [%s]: Within 50m! This should definitely hit!" % torpedo_id)
		print("  - Speed: %.1f km/s" % (velocity_mps.length() / 1000.0))
		print("  - Areas detected in range: %s" % get_overlapping_areas())
		
	if distance_meters < 10.0 and last_distance_logged > 10.0:
		print("COLLISION CRITICAL [%s]: Within 10m! Checking for collision failure..." % torpedo_id)
		
		# Try manual collision check
		var overlapping = get_overlapping_areas()
		print("  - Overlapping areas: %d" % overlapping.size())
		for area in overlapping:
			print("    - Found: %s (faction: %s)" % [area.name, area.get("faction")])
		
		# Check if we're in correct groups
		print("  - Torpedo in groups: %s" % get_groups())
		print("  - Target in groups: %s" % target_node.get_groups())
	
	last_distance_logged = distance_meters

func update_closest_approach():
	"""Track the closest approach distance to the target"""
	if not target_node or not is_instance_valid(target_node):
		return
	
	var current_distance = global_position.distance_to(target_node.global_position)
	var current_distance_meters = current_distance * WorldSettings.meters_per_pixel
	
	if current_distance_meters < closest_approach_distance:
		closest_approach_distance = current_distance_meters
		closest_approach_time = time_since_launch

func calculate_true_intercept(target_pos: Vector2, target_velocity: Vector2) -> Vector2:
	"""Calculate the true intercept point using iterative physics-based approach"""
	
	# Convert velocities to pixels/second for calculation
	var target_vel_pixels = target_velocity / WorldSettings.meters_per_pixel
	var our_pos = global_position
	var our_velocity = velocity_mps
	
	# Start with simple linear intercept estimate
	var intercept = target_pos
	var time_to_intercept = 0.0
	
	# Iteratively refine the intercept calculation
	for iteration in range(intercept_iterations):
		# Calculate vector to current intercept estimate
		var to_intercept = intercept - our_pos
		var distance_meters = to_intercept.length() * WorldSettings.meters_per_pixel
		
		# Calculate our average speed to intercept
		# We start at current speed and accelerate
		var current_speed = our_velocity.length()
		
		# Account for acceleration during intercept
		# Using kinematic equation: d = v0*t + 0.5*a*t^2
		# Rearranged: t^2 + (2*v0/a)*t - (2*d/a) = 0
		# Solving quadratic for time
		var a = 0.5 * acceleration
		var b = current_speed
		var c = -distance_meters
		
		# Quadratic formula (only positive root makes sense)
		var discriminant = b * b - 4 * a * c
		if discriminant < 0:
			# Can't reach target - use simple calculation
			time_to_intercept = distance_meters / max(current_speed, 100.0)
		else:
			time_to_intercept = (-b + sqrt(discriminant)) / (2 * a)
		
		# Sanity check
		time_to_intercept = max(time_to_intercept, 0.1)
		
		# Calculate where target will be at that time
		var new_intercept = target_pos + target_vel_pixels * time_to_intercept
		
		# Check convergence
		if new_intercept.distance_to(intercept) < 1.0:
			break
		
		intercept = new_intercept
	
	return intercept

func generate_intercept_trajectory():
	"""Generate a curved intercept trajectory using physics-based calculation"""
	if not target_node or not is_instance_valid(target_node):
		return
	
	var target_pos = target_node.global_position
	var target_velocity = Vector2.ZERO
	if target_node.has_method("get_velocity_mps"):
		target_velocity = target_node.get_velocity_mps()
	
	# Calculate true physics-based intercept point
	intercept_point = calculate_true_intercept(target_pos, target_velocity)
	
	# Generate curved trajectory
	trajectory_curve.clear()
	
	# Calculate control point for quadratic curve
	var start_pos = global_position
	var end_pos = intercept_point
	var midpoint = (start_pos + end_pos) * 0.5
	
	# Create perpendicular offset for curve
	var direction = (end_pos - start_pos).normalized()
	var perpendicular = Vector2(-direction.y, direction.x)
	
	# Curve control point - offset perpendicular to direct path
	var curve_offset = perpendicular * (start_pos.distance_to(end_pos) * curve_strength)
	
	# If we have velocity, bias the curve in the direction of our current heading
	if velocity_mps.length() > 10:
		var velocity_pixels = velocity_mps / WorldSettings.meters_per_pixel
		var velocity_dir = velocity_pixels.normalized()
		# Blend between perpendicular and velocity direction for smoother curves
		curve_offset = curve_offset * 0.5 + velocity_dir * (start_pos.distance_to(end_pos) * curve_strength * 0.5)
	
	var control_point = midpoint + curve_offset
	
	# Generate points along the quadratic curve for visualization
	for i in range(trajectory_points + 1):
		var t = float(i) / float(trajectory_points)
		var point = calculate_quadratic_point(start_pos, control_point, end_pos, t)
		trajectory_curve.append(point)
	
	# Find our current position on the curve (closest point)
	find_closest_point_on_curve()

func calculate_quadratic_point(p0: Vector2, p1: Vector2, p2: Vector2, t: float) -> Vector2:
	"""Calculate point on quadratic Bezier curve"""
	var u = 1.0 - t
	return u * u * p0 + 2.0 * u * t * p1 + t * t * p2

func find_closest_point_on_curve():
	"""Find the closest point on the trajectory curve to our current position"""
	if trajectory_curve.is_empty():
		return
	
	var min_dist = INF
	var closest_idx = 0
	
	for i in range(trajectory_curve.size()):
		var dist = global_position.distance_squared_to(trajectory_curve[i])
		if dist < min_dist:
			min_dist = dist
			closest_idx = i
	
	# Update curve parameter
	curve_t = float(closest_idx) / float(trajectory_points)
	
	# Get the actual closest point (could interpolate for smoother following)
	if closest_idx < trajectory_curve.size() - 1:
		var p1 = trajectory_curve[closest_idx]
		var p2 = trajectory_curve[closest_idx + 1]
		
		# Project our position onto the line segment
		var segment = p2 - p1
		var to_pos = global_position - p1
		var projection = to_pos.dot(segment) / segment.length_squared()
		projection = clamp(projection, 0.0, 1.0)
		
		closest_point_on_curve = p1 + segment * projection
	else:
		closest_point_on_curve = trajectory_curve[closest_idx]

func follow_trajectory_with_pn(delta):
	"""Use Proportional Navigation to follow the curved trajectory"""
	
	if not target_node or not is_instance_valid(target_node):
		return
	
	# Get current navigation constant based on time
	var current_nav_constant = get_current_navigation_constant()
	
	if trajectory_curve.is_empty():
		# No trajectory yet - aim directly at target
		var to_target = target_node.global_position - global_position
		var desired_angle = to_target.angle() + PI/2
		var angle_error = atan2(sin(desired_angle - rotation), cos(desired_angle - rotation))
		var turn_rate = clamp(angle_error * 5.0, -deg_to_rad(max_turn_rate), deg_to_rad(max_turn_rate))
		rotation += turn_rate * delta
		return
	
	# Look ahead on the curve for our aim point
	var look_ahead_distance = velocity_mps.length() * 0.5  # Look ahead based on speed
	var look_ahead_pixels = look_ahead_distance / WorldSettings.meters_per_pixel
	
	# Find aim point ahead on the curve
	var aim_point = closest_point_on_curve
	var current_idx = int(curve_t * trajectory_points)
	
	# Search forward along the curve for look-ahead point
	var accumulated_dist = 0.0
	for i in range(current_idx, min(current_idx + 10, trajectory_curve.size() - 1)):
		if i + 1 < trajectory_curve.size():
			var segment_length = trajectory_curve[i].distance_to(trajectory_curve[i + 1])
			accumulated_dist += segment_length
			if accumulated_dist >= look_ahead_pixels:
				aim_point = trajectory_curve[i + 1]
				break
			aim_point = trajectory_curve[i + 1]
	
	# Calculate LOS to aim point
	var los_vector = aim_point - global_position
	var los_angle = los_vector.angle()
	
	# Calculate LOS rate for PN
	var los_rate = 0.0
	if last_los_angle != 0.0:
		var angle_diff = atan2(sin(los_angle - last_los_angle), cos(los_angle - last_los_angle))
		los_rate = angle_diff / delta
	last_los_angle = los_angle
	
	# Proportional Navigation law with scheduled gain
	var commanded_turn_rate = current_nav_constant * los_rate
	
	# Add direct heading correction toward aim point
	var current_heading = rotation - PI/2
	var heading_error = atan2(sin(los_angle - current_heading), cos(los_angle - current_heading))
	
	# Stronger heading correction for better curve following
	commanded_turn_rate += heading_error * 8.0
	
	# Apply turn rate limits
	commanded_turn_rate = clamp(commanded_turn_rate, -deg_to_rad(max_turn_rate), deg_to_rad(max_turn_rate))
	
	# Apply rotation
	rotation += commanded_turn_rate * delta

func update_trajectory_visualization():
	if not trajectory_line or trajectory_curve.is_empty():
		return
	
	# Get camera for line width scaling
	var cam = get_viewport().get_camera_2d()
	var scale_factor = 1.0
	if cam:
		scale_factor = 1.0 / cam.zoom.x
	
	# Update trajectory line
	trajectory_line.clear_points()
	trajectory_line.width = 2.0 * scale_factor
	trajectory_line.default_color = Color.ORANGE
	
	# Draw from current position onward
	trajectory_line.add_point(global_position)
	
	# Add remaining trajectory points
	var current_idx = int(curve_t * trajectory_points)
	for i in range(current_idx + 1, trajectory_curve.size()):
		trajectory_line.add_point(trajectory_curve[i])

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
	
	# Calculate heading error to aim point
	var heading_error = 0.0
	if not trajectory_curve.is_empty():
		var current_idx = int(curve_t * trajectory_points)
		if current_idx < trajectory_curve.size() - 1:
			var aim_point = trajectory_curve[min(current_idx + 5, trajectory_curve.size() - 1)]
			var to_aim = aim_point - global_position
			var desired_heading = to_aim.angle()
			var current_heading = rotation - PI/2
			heading_error = rad_to_deg(atan2(sin(desired_heading - current_heading), cos(desired_heading - current_heading)))
	
	var progress = curve_t * 100.0
	
	# Get current gain and determine phase
	var current_gain = get_current_navigation_constant()
	var gain_phase = "initial"
	var gain_info = ""
	
	if time_since_launch <= gain_hold_time:
		gain_phase = "initial"
		if not initial_gain_logged:
			print("Torpedo %s: Initial gain N=%.1f" % [torpedo_id, current_gain])
			initial_gain_logged = true
		gain_info = " | N=%.0f" % current_gain
	elif time_since_launch <= gain_hold_time + gain_ramp_time:
		gain_phase = "ramping"
		var ramp_progress = (time_since_launch - gain_hold_time) / gain_ramp_time * 100.0
		gain_info = " | N=%.0f (ramping %.0f%%)" % [current_gain, ramp_progress]
		
		# Log when we start ramping
		if last_gain_phase == "initial":
			print("Torpedo %s: Starting gain ramp-up from %.1f to %.1f" % [torpedo_id, navigation_constant_initial, navigation_constant_final])
	else:
		gain_phase = "max"
		if not max_gain_logged:
			print("Torpedo %s: Max gain reached N=%.1f" % [torpedo_id, current_gain])
			max_gain_logged = true
		gain_info = " | N=%.0f (MAX)" % current_gain
	
	last_gain_phase = gain_phase
	
	print("Torpedo %s: %.1f km/s | Target: %.1f km | Intercept: %.1f km | Progress: %.0f%% | Error: %.1f°%s" % 
		[torpedo_id, speed_kms, range_km, intercept_range_km, progress, heading_error, gain_info])

func check_world_bounds():
	var half_size = WorldSettings.map_size_pixels / 2
	if abs(global_position.x) > half_size.x or abs(global_position.y) > half_size.y:
		mark_for_destruction("out_of_bounds")

func _on_area_entered(area: Area2D):
	print("COLLISION DEBUG [%s]: _on_area_entered triggered!" % torpedo_id)
	print("  - Collided with: %s" % area.name)
	print("  - Area groups: %s" % area.get_groups())
	print("  - Area faction: %s" % area.get("faction"))
	
	if marked_for_death or not is_alive:
		print("  - Torpedo already dead, ignoring collision")
		return
	
	if area.is_in_group("ships"):
		print("  - Target is a ship!")
		if area.get("faction") == faction:
			print("  - Same faction (%s), ignoring" % faction)
			return
		
		print("COLLISION SUCCESS [%s]: HIT TARGET %s!" % [torpedo_id, area.name])
		print("  - Impact at: %.1f km distance" % closest_approach_distance)
		print("  - Impact time: %.1fs" % time_since_launch)
		print("  - Impact speed: %.1f km/s" % (velocity_mps.length() / 1000.0))
		
		if area.has_method("mark_for_destruction"):
			area.mark_for_destruction("torpedo_impact")
		
		mark_for_destruction("target_impact")
	else:
		print("  - Not a ship, ignoring")

func mark_for_destruction(reason: String):
	if marked_for_death:
		return
	
	marked_for_death = true
	is_alive = false
	
	# Log destruction with detailed info
	if reason == "out_of_bounds" and closest_approach_distance < INF:
		var closest_km = closest_approach_distance / 1000.0
		print("DESTRUCTION [%s]: %s | CLOSEST APPROACH: %.3f km (%.1f m) at %.1fs" % 
			[torpedo_id, reason, closest_km, closest_approach_distance, closest_approach_time])
		
		# If we got very close but still "missed", it's probably a collision bug
		if closest_approach_distance < 100.0:
			print("  - WARNING: Very close approach but no collision detected!")
			print("  - This suggests collision shapes may be too small or misaligned")
	elif reason == "target_impact":
		print("DESTRUCTION [%s]: SUCCESSFUL IMPACT!" % torpedo_id)
		print("  - Final distance: %.1f m" % closest_approach_distance)
		print("  - Impact time: %.1fs" % time_since_launch)
	else:
		print("DESTRUCTION [%s]: %s" % [torpedo_id, reason])
	
	# Hide visualization
	if trajectory_line:
		trajectory_line.visible = false
	
	set_physics_process(false)
	var collision = get_node_or_null("CollisionShape2D")
	if collision:
		collision.disabled = true
		print("  - Collision shape disabled for cleanup")
	
	queue_free()

# Public interface
func set_target(target: Node2D):
	target_node = target
	print("  - Target set: %s" % target_node.name if target_node else "null")

func set_launcher(launcher_ship: Node2D):
	if "faction" in launcher_ship:
		faction = launcher_ship.faction
		print("  - Launcher faction: %s" % faction)

func get_velocity_mps() -> Vector2:
	return velocity_mps

func get_collision_debug_info() -> Dictionary:
	"""Returns detailed collision debugging information"""
	var info = {
		"torpedo_id": torpedo_id,
		"alive": is_alive,
		"marked_for_death": marked_for_death,
		"has_target": target_node != null,
		"closest_approach_m": closest_approach_distance,
		"current_distance_m": INF,
		"overlapping_areas": []
	}
	
	if target_node and is_instance_valid(target_node):
		info.current_distance_m = global_position.distance_to(target_node.global_position) * WorldSettings.meters_per_pixel
	
	for area in get_overlapping_areas():
		info.overlapping_areas.append({
			"name": area.name,
			"faction": area.get("faction"),
			"groups": area.get_groups()
		})
	
	return info

# Compatibility
func set_launch_side(_side: int):
	pass

func set_flight_plan(_plan: String, _data: Dictionary = {}):
	pass
