# Scripts/Entities/Weapons/SimpleTorpedo.gd - Simplified Straight-Line PN Version with I-term
extends Area2D

# Static counter for sequential torpedo naming
static var torpedo_counter: int = 0

# Core parameters
@export var acceleration: float = 980.0       # 100G forward thrust
@export var max_turn_rate: float = 1080.0     # degrees/second (3 full rotations)

# Adaptive Proportional Navigation parameters
@export var gain_scale_factor: float = 30.0    # Base gain scaling factor (was 5.0, then 15.0, now 30.0)
@export var min_gain: float = 1.0             # Minimum PN gain
@export var max_gain_multiplier: float = 100.0 # Max gain = sqrt(range_km) * this

## PID augmentation parameters
#@export var derivative_damping: float = 0.75  # D-term coefficient
#@export var integral_gain: float = 0.5       # I-term gain (start conservative)
#@export var integral_max: float = 1.0         # Anti-windup limit

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
var initial_target_distance: float = 0.0      # Store initial range for scaling
var expected_flight_time: float = 0.0         # Estimated total flight time

# PN state
var current_gain: float = 1.0                 # THE single source of truth for gain
var last_los_angle: float = 0.0
var last_heading_error: float = 0.0
var error_rate: float = 0.0

## I-term state (NEW!)
#var error_integral: float = 0.0               # Accumulated error over time
#var integral_enabled: bool = true             # Can disable for testing

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
var last_logged_progress: float = -1.0
var last_error_reduction_logged: float = 0.0

func _ready():
	Engine.max_fps = 60
	
	# Generate sequential torpedo ID
	torpedo_counter += 1
	torpedo_id = "Torp_%d" % torpedo_counter
	print("  - Initial rotation: %.1f degrees" % rad_to_deg(rotation))
	
	add_to_group("torpedoes")
	add_to_group("combat_entities")
	
	set_meta("torpedo_id", torpedo_id)
	set_meta("faction", faction)
	set_meta("entity_type", "torpedo")
	
	# Collision setup logging
	print("Torpedo %s launched - ADAPTIVE PN GUIDANCE with I-term" % torpedo_id)
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
	
	# Initialize adaptive gain system will happen when target is set
	print("  - Gain: Adaptive system with PID augmentation")
	
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

func calculate_adaptive_gain() -> float:
	"""Single unified gain calculation - THE source of truth for PN gain"""
	if not target_node or not is_instance_valid(target_node):
		return min_gain
	
	# Get current state
	var current_distance = global_position.distance_to(target_node.global_position)
	var current_distance_meters = current_distance * WorldSettings.meters_per_pixel
	var current_speed = velocity_mps.length()
	var time_to_impact = calculate_time_to_impact()
	
	# Calculate dimensionless progress (0 at launch, 1 at impact)
	var progress = 1.0 - (current_distance_meters / initial_target_distance)
	progress = clamp(progress, 0.0, 1.0)
	
	# Calculate base gain scaled to engagement range
	var range_km = initial_target_distance / 1000.0
	var base_gain = sqrt(range_km) * gain_scale_factor
	base_gain = clamp(base_gain, min_gain, sqrt(range_km) * max_gain_multiplier)
	
	# Three-phase gain profile
	var phase_gain: float
	
	if progress < 0.05:  # First 5% of flight - Launch phase
		# Gentle ramp up to avoid oscillations (but stronger than before)
		phase_gain = min_gain + (base_gain - min_gain) * (progress / 0.05) * 0.6  # Was 0.3
		
	elif progress < 0.70:  # 5-70% of flight - Mid-course phase (was 80%)
		# Full gain, scaled by velocity ratio for stability
		var expected_speed = acceleration * time_since_launch  # Rough estimate
		var velocity_factor = clamp(current_speed / expected_speed, 0.5, 2.0)
		phase_gain = base_gain * velocity_factor
		
	else:  # Final 30% of flight - Terminal phase (was 20%)
		# More gradual taper based on time to impact
		var terminal_factor: float
		if time_to_impact > 30.0:
			terminal_factor = 1.0
		elif time_to_impact > 20.0:
			# Very gradual reduction from 30s to 20s
			terminal_factor = 0.7 + 0.3 * ((time_to_impact - 20.0) / 10.0)
		elif time_to_impact > 10.0:
			# Gradual reduction from 20s to 10s
			terminal_factor = 0.4 + 0.3 * ((time_to_impact - 10.0) / 10.0)
		elif time_to_impact > 5.0:
			# Steeper reduction from 10s to 5s
			terminal_factor = 0.15 + 0.25 * ((time_to_impact - 5.0) / 5.0)
		elif time_to_impact > 2.0:
			# Significant reduction from 5s to 2s
			terminal_factor = 0.05 + 0.10 * ((time_to_impact - 2.0) / 3.0)
		else:
			# Minimal gain in final 2 seconds
			terminal_factor = 0.02 + 0.03 * (time_to_impact / 2.0)
		
		phase_gain = base_gain * terminal_factor
	
	# Apply error-based damping (always active, not just terminal)
	if abs(error_rate) > 5.0:  # Rapid oscillation
		phase_gain *= 0.3
	elif abs(error_rate) > 2.0:  # Moderate oscillation
		phase_gain *= 0.6
	elif abs(error_rate) > 1.0:  # Light oscillation
		phase_gain *= 0.85
	
	# Additional error magnitude limiting - reduce gain if error is too large
	var heading_error_deg = rad_to_deg(abs(last_heading_error))
	if heading_error_deg > 2.0:  # Raised threshold from 1.0 to 2.0
		# Reduce gain proportionally when error exceeds 2 degrees
		var error_factor = 2.0 / heading_error_deg  # 2° = 100%, 4° = 50%, etc.
		var old_gain = phase_gain
		phase_gain *= clamp(error_factor, 0.3, 1.0)  # Don't reduce by more than 70%
		
		# Log significant error-based reductions (only once per second)
		var current_time = Time.get_ticks_msec() / 1000.0
		if current_time - last_error_reduction_logged > 1.0:
			print("%s: ERROR LIMITING - %.1f° error, gain %.0f -> %.0f" % 
				[torpedo_id, heading_error_deg, old_gain, phase_gain])
			last_error_reduction_logged = current_time
	
	# Ensure minimum gain
	phase_gain = max(phase_gain, min_gain)
	
	return phase_gain

func _physics_process(delta):
	if marked_for_death or not is_alive or not target_node:
		return
	
	if not is_instance_valid(target_node):
		mark_for_destruction("lost_target")
		return
	
	# Initialize on first frame when we're actually positioned
	if initial_target_distance <= 0 and target_node:
		initial_target_distance = global_position.distance_to(target_node.global_position) * WorldSettings.meters_per_pixel
		expected_flight_time = sqrt(2.0 * initial_target_distance / acceleration)
		var range_km = initial_target_distance / 1000.0
		var base_gain = sqrt(range_km) * gain_scale_factor
		base_gain = clamp(base_gain, min_gain, sqrt(range_km) * max_gain_multiplier)
		print("%s: Initialized at launch - range %.1f km, base gain %.1f" % [torpedo_id, range_km, base_gain])
	
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
	"""Apply Proportional Navigation with PID augmentation to track the intercept point"""
	
	if not target_node or not is_instance_valid(target_node):
		return
	
	# Calculate heading error first (needed for error rate and I-term)
	var los_vector = intercept_point - global_position
	var desired_heading = los_vector.angle()
	var current_heading = rotation - PI/2
	var heading_error = atan2(sin(desired_heading - current_heading), cos(desired_heading - current_heading))
	
	## I-TERM: Accumulate error over time (NEW!)
	#if integral_enabled:
		#error_integral += heading_error * delta
		## Anti-windup: prevent integral from growing too large
		#error_integral = clamp(error_integral, -integral_max, integral_max)
	
	# Calculate error growth rate (for D-term)
	if last_heading_error != 0.0:  # Skip first frame
		error_rate = rad_to_deg(heading_error - last_heading_error) / delta
	last_heading_error = heading_error
	
	# SINGLE SOURCE OF TRUTH: Calculate gain once per frame
	current_gain = calculate_adaptive_gain()
	
	# Calculate LOS angle
	var los_angle = los_vector.angle()
	
	# Calculate LOS rate for PN
	var los_rate = 0.0
	if last_los_angle != 0.0:
		var angle_diff = atan2(sin(los_angle - last_los_angle), cos(los_angle - last_los_angle))
		los_rate = angle_diff / delta
	last_los_angle = los_angle
	
	# Proportional Navigation law with THE current gain
	var commanded_turn_rate = current_gain * los_rate
	
	# P-TERM: Heading correction - scales with PN gain for better authority
	var time_to_impact = calculate_time_to_impact()
	var heading_correction_gain = 3.0 + (current_gain * 0.02)  # Scales with PN gain
	if time_to_impact < 10.0:
		# Even more aggressive in terminal phase
		heading_correction_gain = 5.0 + (current_gain * 0.03)
	commanded_turn_rate += heading_error * heading_correction_gain
	
	## I-TERM: Add integral correction (NEW!)
	#commanded_turn_rate += error_integral * integral_gain
	
	## D-TERM: Derivative damping - resist error growth
	#var error_damping = deg_to_rad(error_rate) * derivative_damping  # Using export variable
	#commanded_turn_rate -= error_damping  # Oppose the direction of error growth
	
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
	
	# Add time of flight
	var tof_str = "ToF: %.1fs" % time_since_launch
	
	# Format gain string - now just shows the current adaptive gain
	var gain_str = "PN: %.0f" % current_gain
	
	## Add I-term value (NEW!)
	#var i_str = "I: %.2f" % error_integral
	
	# Calculate progress for additional debug info
	var current_distance_meters = global_position.distance_to(target_node.global_position) * WorldSettings.meters_per_pixel
	var progress = 1.0 - (current_distance_meters / initial_target_distance)
	if abs(progress - last_logged_progress) > 0.1:  # Log phase changes
		var phase = "Launch" if progress < 0.05 else "Mid-course" if progress < 0.70 else "Terminal"
		print("%s: Entering %s phase (%.0f%% complete)" % [torpedo_id, phase, progress * 100])
		last_logged_progress = progress
	
	# Updated debug output with I-term
	print("%s: %.1f km/s | Tgt: %.1f km | Int: %.1f km | Err: %.1f° | %s | %s | %s | %s" % 
		[torpedo_id, speed_kms, range_km, intercept_range_km, heading_error, err_rate_str, gain_str, tof_str, tti_str])

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
		#print("  - Final integral value: %.3f" % error_integral)  # NEW!
		
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
		# Initial distance will be calculated on first physics frame
		# when torpedo is actually positioned
	else:
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
