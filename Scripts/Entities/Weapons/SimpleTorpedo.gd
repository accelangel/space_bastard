# Scripts/Entities/Weapons/SimpleTorpedo.gd - Simplified Straight-Line PN Version
extends Area2D

# Core parameters
@export var acceleration: float = 980.0       # 100G forward thrust
@export var max_turn_rate: float = 1080.0     # degrees/second (3 full rotations)

# Proportional Navigation with gain scheduling
@export var navigation_constant_initial: float = 1.0  # N value at launch
@export var navigation_constant_final: float = 500.0  # N value after ramp-up
@export var gain_hold_time: float = 3.0       # Hold initial gain for this long
@export var gain_ramp_time: float = 15.0      # Ramp up over this duration

# Trajectory parameters
@export var trajectory_points: int = 50       # Points for visualization
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

# PN state
var last_los_angle: float = 0.0
var last_heading_error: float = 0.0
var error_rate: float = 0.0
var terminal_reduction_logged: bool = false

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
var last_gain_phase: String = "initial"

func _ready():
	Engine.max_fps = 60
	
	torpedo_id = "T%d" % [get_instance_id() % 10000]  # Shorter ID for cleaner logs
	print("  - Initial rotation: %.1f degrees" % rad_to_deg(rotation))
	
	add_to_group("torpedoes")
	add_to_group("combat_entities")
	
	set_meta("torpedo_id", torpedo_id)
	set_meta("faction", faction)
	set_meta("entity_type", "torpedo")
	
	# Collision setup logging
	print("Torpedo %s launched - STRAIGHT-LINE PN GUIDANCE" % torpedo_id)
	print("  - Faction: %s" % faction)
	print("  - Groups: %s" % get_groups())
	
	# Check collision shape
	var collision_shape = get_node_or_null("CollisionShape2D")
	var animated_sprite = get_node_or_null("AnimatedSprite2D")
	if animated_sprite:
		var sprite_collision = animated_sprite.get_node_or_null("CollisionShape2D")
		if sprite_collision:
			collision_shape = sprite_collision
	
	if collision_shape:
		print("  - Collision shape: %s" % collision_shape.shape.get_class())
		if collision_shape.shape is CapsuleShape2D:
			print("  - Capsule: radius=%.1f, height=%.1f pixels" % 
				[collision_shape.shape.radius, collision_shape.shape.height])
	
	# Connect collision signal
	area_entered.connect(_on_area_entered)
	
	# Log gain scheduling
	print("  - Gain: N=%.1f initial, ramping to N=%.1f over %.1f-%.1fs" % 
		[navigation_constant_initial, navigation_constant_final, gain_hold_time, gain_hold_time + gain_ramp_time])
	
	var sprite = get_node_or_null("AnimatedSprite2D")
	if sprite:
		sprite.play()
	
	# Setup trajectory visualization
	setup_trajectory_line()

func setup_trajectory_line():
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
		return navigation_constant_initial
	elif time_since_launch <= gain_hold_time + gain_ramp_time:
		var ramp_progress = (time_since_launch - gain_hold_time) / gain_ramp_time
		return lerp(navigation_constant_initial, navigation_constant_final, ramp_progress)
	else:
		return navigation_constant_final

func _physics_process(delta):
	if marked_for_death or not is_alive or not target_node:
		return
	
	if not is_instance_valid(target_node):
		mark_for_destruction("lost_target")
		return
	
	# Update time tracking
	time_since_launch += delta
	
	# Track closest approach
	update_closest_approach()
	
	# Check proximity for collision debugging
	check_proximity_collision()
	
	# Calculate intercept point
	calculate_intercept()
	
	# Apply PN guidance to track intercept
	apply_pn_guidance(delta)
	
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
		print("COLLISION DEBUG [%s]: Within 100m! Distance: %.1f m" % [torpedo_id, distance_meters])
	
	if distance_meters < 50.0 and last_distance_logged > 50.0:
		print("COLLISION DEBUG [%s]: Within 50m! Should hit!" % torpedo_id)
		
	if distance_meters < 10.0 and last_distance_logged > 10.0:
		print("COLLISION CRITICAL [%s]: Within 10m!" % torpedo_id)
	
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

func calculate_intercept():
	"""Calculate the intercept point using physics-based approach"""
	if not target_node or not is_instance_valid(target_node):
		return
	
	var target_velocity = Vector2.ZERO
	if target_node.has_method("get_velocity_mps"):
		target_velocity = target_node.get_velocity_mps()
	
	intercept_point = calculate_true_intercept(target_node.global_position, target_velocity)

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
		var current_speed = our_velocity.length()
		
		# Using kinematic equation: d = v0*t + 0.5*a*t^2
		# Rearranged: t^2 + (2*v0/a)*t - (2*d/a) = 0
		var a = 0.5 * acceleration
		var b = current_speed
		var c = -distance_meters
		
		# Quadratic formula (only positive root makes sense)
		var discriminant = b * b - 4 * a * c
		if discriminant < 0:
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

func calculate_time_to_impact() -> float:
	"""Calculate estimated time to impact based on current velocity and distance"""
	if not target_node or not is_instance_valid(target_node):
		return INF
	
	var distance_to_target = global_position.distance_to(target_node.global_position)
	var distance_meters = distance_to_target * WorldSettings.meters_per_pixel
	
	# Get closing velocity (component of our velocity toward target)
	var to_target = (target_node.global_position - global_position).normalized()
	var closing_velocity = velocity_mps.dot(to_target)
	
	# At launch, estimate based on physics
	if closing_velocity < 1000.0:  # Less than 1 km/s closing
		# Use kinematic equation to estimate time given constant acceleration
		# d = v0*t + 0.5*a*t^2
		# Solving for t with v0 near 0 gives approximately: t = sqrt(2*d/a)
		var estimated_time = sqrt(2.0 * distance_meters / acceleration)
		return estimated_time
		
	return distance_meters / closing_velocity

func apply_pn_guidance(delta):
	"""Apply Proportional Navigation to track the intercept point"""
	
	if not target_node or not is_instance_valid(target_node):
		return
	
	# Calculate heading error first (needed for error rate)
	var los_vector = intercept_point - global_position
	var desired_heading = los_vector.angle()
	var current_heading = rotation - PI/2
	var heading_error = atan2(sin(desired_heading - current_heading), cos(desired_heading - current_heading))
	
	# Calculate error growth rate
	if last_heading_error != 0.0:  # Skip first frame
		error_rate = rad_to_deg(heading_error - last_heading_error) / delta
	last_heading_error = heading_error
	
	# Get base navigation constant based on time
	var current_nav_constant = get_current_navigation_constant()
	
	# Error rate-based gain reduction for terminal phase
	var time_to_impact = calculate_time_to_impact()
	
	# More aggressive terminal reduction based on both error magnitude AND rate
	if time_to_impact < 30.0:
		var should_reduce = false
		var reduction_reason = ""
		
		# Check for rapid error growth
		if abs(error_rate) > 3.0:  # Reduced from 5.0
			should_reduce = true
			reduction_reason = "rapid error rate %.1f°/s" % error_rate
		# Check for accumulated error in terminal phase
		elif time_to_impact < 10.0 and abs(rad_to_deg(heading_error)) > 1.0:  # Reduced from 1.5
			should_reduce = true
			reduction_reason = "terminal error %.1f°" % rad_to_deg(heading_error)
		# Check for slow but steady error growth - MORE AGGRESSIVE
		elif error_rate > 0.1 and abs(rad_to_deg(heading_error)) > 0.8:  # Reduced from 0.2 and 1.0
			should_reduce = true
			reduction_reason = "error creep %.1f° at %.2f°/s" % [rad_to_deg(heading_error), error_rate]
		
		if should_reduce:
			var old_gain = current_nav_constant
			# More aggressive reduction based on how bad things are
			var terminal_gain = 5.0  # Reduced from 10.0
			if abs(error_rate) > 10.0:
				terminal_gain = 2.0  # Reduced from 5.0
			elif time_to_impact < 3.0:
				terminal_gain = 3.0  # Very low gain in final seconds
			
			# More aggressive reduction factor
			var error_factor = clamp(abs(rad_to_deg(heading_error)) / 2.0, 0.5, 1.0)  # Changed from /3.0 to /2.0
			current_nav_constant = lerp(current_nav_constant, terminal_gain, error_factor)
			
			# Log only significant reductions, and only once
			if not terminal_reduction_logged and old_gain / current_nav_constant > 1.5:  # Reduced from 2
				print("%s: TERMINAL REDUCTION - %s, gain %.0f -> %.0f" % 
					[torpedo_id, reduction_reason, old_gain, current_nav_constant])
				terminal_reduction_logged = true
	
	# Log gain phase changes (for initial ramp-up)
	if time_since_launch <= gain_hold_time:
		if not initial_gain_logged:
			print("%s: Initial gain N=%.1f" % [torpedo_id, current_nav_constant])
			initial_gain_logged = true
	elif time_since_launch <= gain_hold_time + gain_ramp_time:
		if last_gain_phase == "initial":
			print("%s: Starting gain ramp-up from %.1f to %.1f" % 
				[torpedo_id, navigation_constant_initial, navigation_constant_final])
		last_gain_phase = "ramping"
	else:
		if not max_gain_logged and last_gain_phase != "max":
			print("%s: Max gain reached N=%.1f" % [torpedo_id, navigation_constant_final])
			max_gain_logged = true
		last_gain_phase = "max"
	
	# Calculate LOS angle (already have los_vector from earlier)
	var los_angle = los_vector.angle()
	
	# Calculate LOS rate for PN
	var los_rate = 0.0
	if last_los_angle != 0.0:
		var angle_diff = atan2(sin(los_angle - last_los_angle), cos(los_angle - last_los_angle))
		los_rate = angle_diff / delta
	last_los_angle = los_angle
	
	# Proportional Navigation law
	var commanded_turn_rate = current_nav_constant * los_rate
	
	# Heading correction - more aggressive in terminal phase
	var heading_correction_gain = 3.0
	if time_to_impact < 10.0:
		heading_correction_gain = 5.0  # More aggressive heading correction near impact
	commanded_turn_rate += heading_error * heading_correction_gain
	
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
	
	# Update trajectory line - simple straight line to intercept
	trajectory_line.clear_points()
	trajectory_line.width = 2.0 * scale_factor
	trajectory_line.default_color = Color.ORANGE
	
	# Draw straight line from current position to intercept
	trajectory_line.add_point(global_position)
	trajectory_line.add_point(intercept_point)

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
	
	# Calculate heading error
	var los_vector = intercept_point - global_position
	var desired_heading = los_vector.angle()
	var current_heading = rotation - PI/2
	var heading_error = rad_to_deg(atan2(sin(desired_heading - current_heading), cos(desired_heading - current_heading)))
	
	# Get time to impact
	var tti = calculate_time_to_impact()
	var tti_str = ""
	if tti < 100.0:
		tti_str = "TTI: %.1fs" % tti
	elif tti < INF:
		tti_str = "TTI: %.0fs" % tti  # No decimal for large values
	else:
		tti_str = "TTI: ---"
	
	# Format error rate
	var err_rate_str = "ΔErr: %.1f°/s" % error_rate
	
	# Get current gain (AFTER any terminal reduction)
	var display_gain = get_current_navigation_constant()
	
	# Apply same terminal reduction logic for display
	if tti < 30.0:
		var should_reduce_display = false
		if abs(error_rate) > 3.0:
			should_reduce_display = true
		elif tti < 10.0 and abs(heading_error) > 1.0:
			should_reduce_display = true
		elif error_rate > 0.1 and abs(heading_error) > 0.8:
			should_reduce_display = true
			
		if should_reduce_display:
			var terminal_gain = 5.0
			if abs(error_rate) > 10.0:
				terminal_gain = 2.0
			elif tti < 3.0:
				terminal_gain = 3.0
			var error_factor = clamp(abs(heading_error) / 2.0, 0.5, 1.0)
			display_gain = lerp(display_gain, terminal_gain, error_factor)
	
	# Add time of flight
	var tof_str = "ToF: %.1fs" % time_since_launch
	
	# Format: "T1: 102.8 km/s | Tgt: 221.7 km | Int: 222.9 km | Err: 2.7° | ToF: 10.2s | TTI: 2.2s | ΔErr: 5.1°/s | PN: 50"
	var gain_str = ""
	if time_since_launch <= gain_hold_time:
		gain_str = "PN: %.0f" % display_gain
	elif time_since_launch <= gain_hold_time + gain_ramp_time:
		var ramp_progress = (time_since_launch - gain_hold_time) / gain_ramp_time * 100.0
		gain_str = "PN: %.0f (%.0f%%)" % [display_gain, ramp_progress]
	else:
		gain_str = "PN: %.0f" % display_gain
	
	print("%s: %.1f km/s | Tgt: %.1f km | Int: %.1f km | Err: %.1f° | %s | %s | %s | %s" % 
		[torpedo_id, speed_kms, range_km, intercept_range_km, heading_error, tof_str, tti_str, err_rate_str, gain_str])

func check_world_bounds():
	var half_size = WorldSettings.map_size_pixels / 2
	if abs(global_position.x) > half_size.x or abs(global_position.y) > half_size.y:
		mark_for_destruction("out_of_bounds")

func _on_area_entered(area: Area2D):
	print("COLLISION [%s]: Hit %s!" % [torpedo_id, area.name])
	
	if marked_for_death or not is_alive:
		return
	
	if area.is_in_group("ships"):
		if area.get("faction") == faction:
			return
		
		# Calculate angle between velocity and orientation
		var velocity_angle = velocity_mps.angle()
		var torpedo_angle = rotation - PI/2  # Convert from Godot rotation to angle
		var velocity_orientation_diff = rad_to_deg(atan2(sin(velocity_angle - torpedo_angle), cos(velocity_angle - torpedo_angle)))
		
		print("SUCCESS [%s]: HIT TARGET %s!" % [torpedo_id, area.name])
		print("  - Impact at: %.1f km" % (closest_approach_distance / 1000.0))
		print("  - Impact time: %.1fs" % time_since_launch)
		print("  - Impact speed: %.1f km/s" % (velocity_mps.length() / 1000.0))
		print("  - Velocity/Orientation angle: %.1f°" % velocity_orientation_diff)
		
		if area.has_method("mark_for_destruction"):
			area.mark_for_destruction("torpedo_impact")
		
		mark_for_destruction("target_impact")

func mark_for_destruction(reason: String):
	if marked_for_death:
		return
	
	marked_for_death = true
	is_alive = false
	
	# Log destruction
	if reason == "out_of_bounds" and closest_approach_distance < INF:
		var closest_km = closest_approach_distance / 1000.0
		print("DESTRUCTION [%s]: %s | Closest: %.3f km at %.1fs" % 
			[torpedo_id, reason, closest_km, closest_approach_time])
		
		if closest_approach_distance < 100.0:
			print("  - WARNING: Very close approach but no collision!")
	elif reason == "target_impact":
		print("DESTRUCTION [%s]: SUCCESSFUL IMPACT!" % torpedo_id)
	else:
		print("DESTRUCTION [%s]: %s" % [torpedo_id, reason])
	
	# Hide visualization
	if trajectory_line:
		trajectory_line.visible = false
	
	set_physics_process(false)
	var collision = get_node_or_null("CollisionShape2D")
	if collision:
		collision.disabled = true
	
	queue_free()

# Public interface
func set_target(target: Node2D):
	target_node = target
	var target_name = "null"
	if target_node:
		target_name = target_node.name
	print("  - Target set: %s" % target_name)

func set_launcher(launcher_ship: Node2D):
	if "faction" in launcher_ship:
		faction = launcher_ship.faction
		print("  - Launcher faction: %s" % faction)

func get_velocity_mps() -> Vector2:
	return velocity_mps

# Compatibility stubs for old interface
func set_launch_side(_side: int):
	pass

func set_flight_plan(_plan: String, _data: Dictionary = {}):
	pass
