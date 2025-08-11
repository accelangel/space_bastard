# Scripts/Entities/Weapons/SimpleTorpedo.gd - VELOCITY-MEASURED PN+P WITH PURE PHYSICS
# Measures error from velocity vector to eliminate bias
# Body rotates freely to generate optimal thrust vector (no alignment constraints!)
# Result: Zero guidance bias, maximum maneuverability against high-G targets
extends Area2D

# Static counter for sequential torpedo naming
static var torpedo_counter: int = 0

# Core parameters
@export var acceleration: float = 980.0       # 100G forward thrust
@export var max_turn_rate: float = 1080.0     # degrees/second (3 full rotations)

# Velocity measurement threshold
@export var min_velocity_for_measurement: float = 10.0  # Min velocity (m/s) for stable angle measurement

# Adaptive Proportional Navigation parameters
@export var gain_scale_factor: float = 30.0    # Base gain scaling factor
@export var min_gain: float = 1.0             # Minimum PN gain
@export var max_gain_multiplier: float = 100.0 # Max gain = sqrt(range_km) * this

# Body alignment parameters (optional, only when flying straight)
@export var body_alignment_rate: float = 8.0   # How quickly torpedo aligns with velocity when not turning
@export var min_velocity_for_alignment: float = 10.0  # Min velocity (m/s) before alignment kicks in

# Trajectory parameters
@export var trajectory_points: int = 50       # Points for visualization
@export var intercept_iterations: int = 10    # Iterations for intercept calculation

# Debug settings
@export var debug_output: bool = true
@export var debug_interval: float = 1.0  # Once per second

# Debug: Bias investigation
@export var debug_bias_investigation: bool = true
@export var debug_bias_interval: float = 5.0  # Every 5 seconds for detailed angle debug
var last_bias_debug_time: float = 0.0

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

# NEW: Track velocity-based heading
var last_velocity_angle: float = 0.0

# Debug: Track angle history for bias investigation
var angle_history: Array = []  # Store last 10 frames of angle data
const MAX_HISTORY: int = 10

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
	
	# DEBUG: Log initial sprite orientation
	if debug_bias_investigation:
		print("[BIAS DEBUG] %s: Initial Godot rotation: %.3f rad (%.1f°)" % 
			[torpedo_id, rotation, rad_to_deg(rotation)])
		print("[BIAS DEBUG] %s: Pure physics - no alignment constraints!" % torpedo_id)
	
	add_to_group("torpedoes")
	add_to_group("combat_entities")
	
	set_meta("torpedo_id", torpedo_id)
	set_meta("faction", faction)
	set_meta("entity_type", "torpedo")
	
	# Collision setup logging
	print("Torpedo %s launched - VELOCITY-MEASURED PN+P (PURE PHYSICS)" % torpedo_id)
	print("  - Faction: %s" % faction)
	
	# Connect collision signal
	area_entered.connect(_on_area_entered)
	
	# Initialize adaptive gain system will happen when target is set
	print("  - Gain: Adaptive PN+P (velocity-measured, thrust vectoring)")
	
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
		phase_gain = min_gain + (base_gain - min_gain) * (progress / 0.05) * 0.6
		
	elif progress < 0.70:  # 5-70% of flight - Mid-course phase
		var expected_speed = acceleration * time_since_launch
		var velocity_factor = clamp(current_speed / expected_speed, 0.5, 2.0)
		phase_gain = base_gain * velocity_factor
		
	else:  # Final 30% of flight - Terminal phase
		var terminal_factor: float
		if time_to_impact > 30.0:
			terminal_factor = 1.0
		elif time_to_impact > 20.0:
			terminal_factor = 0.7 + 0.3 * ((time_to_impact - 20.0) / 10.0)
		elif time_to_impact > 10.0:
			terminal_factor = 0.4 + 0.3 * ((time_to_impact - 10.0) / 10.0)
		elif time_to_impact > 5.0:
			terminal_factor = 0.15 + 0.25 * ((time_to_impact - 5.0) / 5.0)
		elif time_to_impact > 2.0:
			terminal_factor = 0.05 + 0.10 * ((time_to_impact - 2.0) / 3.0)
		else:
			terminal_factor = 0.02 + 0.03 * (time_to_impact / 2.0)
		
		phase_gain = base_gain * terminal_factor
	
	# Apply error-based damping
	if abs(error_rate) > 5.0:
		phase_gain *= 0.3
	elif abs(error_rate) > 2.0:
		phase_gain *= 0.6
	elif abs(error_rate) > 1.0:
		phase_gain *= 0.85
	
	# Additional error magnitude limiting
	var heading_error_deg = rad_to_deg(abs(last_heading_error))
	if heading_error_deg > 2.0:
		var error_factor = 2.0 / heading_error_deg
		var old_gain = phase_gain
		phase_gain *= clamp(error_factor, 0.3, 1.0)
		
		var current_time = Time.get_ticks_msec() / 1000.0
		if current_time - last_error_reduction_logged > 1.0:
			print("%s: ERROR LIMITING - %.1f° error, gain %.0f -> %.0f" % 
				[torpedo_id, heading_error_deg, old_gain, phase_gain])
			last_error_reduction_logged = current_time
	
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
		
		# Initialize velocity angle tracking
		if velocity_mps.length() > 0.1:
			last_velocity_angle = velocity_mps.angle()
	
	# Update time tracking
	time_since_launch += delta
	
	# Track closest approach
	update_closest_approach()
	
	# Check proximity for collision debugging
	check_proximity_collision()
	
	# Calculate intercept point
	calculate_intercept()
	
	# VELOCITY-ALIGNED GUIDANCE
	apply_velocity_aligned_guidance(delta)
	
	# Update position
	var velocity_pixels = velocity_mps / WorldSettings.meters_per_pixel
	global_position += velocity_pixels * delta
	
	# Update visualization
	if trajectory_line:
		update_trajectory_visualization()
	
	# Debug output
	if debug_output:
		update_debug_output()
	
	# Bias investigation debug
	if debug_bias_investigation:
		update_bias_debug()
	
	check_world_bounds()

func apply_velocity_aligned_guidance(delta):
	"""Apply guidance measured from velocity vector, but thrust realistically (forward only)"""
	
	if not target_node or not is_instance_valid(target_node):
		return
	
	# Get current velocity heading (this is where we're ACTUALLY going)
	var velocity_angle = velocity_mps.angle() if velocity_mps.length() > min_velocity_for_measurement else rotation - PI/2
	
	# Calculate heading error based on VELOCITY, not body orientation
	var los_vector = intercept_point - global_position
	var desired_heading = los_vector.angle()
	var heading_error = atan2(sin(desired_heading - velocity_angle), cos(desired_heading - velocity_angle))
	
	# Store angle data for history
	if angle_history.size() >= MAX_HISTORY:
		angle_history.pop_front()
	angle_history.append({
		"time": time_since_launch,
		"heading_error": heading_error,
		"desired_heading": desired_heading,
		"velocity_heading": velocity_angle,
		"body_heading": rotation - PI/2,
		"los_angle": los_vector.angle()
	})
	
	# Calculate error growth rate
	if last_heading_error != 0.0:
		error_rate = rad_to_deg(heading_error - last_heading_error) / delta
	last_heading_error = heading_error
	
	# Calculate gain
	current_gain = calculate_adaptive_gain()
	
	# Calculate LOS angle and rate
	var los_angle = los_vector.angle()
	var los_rate = 0.0
	if last_los_angle != 0.0:
		var angle_diff = atan2(sin(los_angle - last_los_angle), cos(los_angle - last_los_angle))
		los_rate = angle_diff / delta
	last_los_angle = los_angle
	
	# VELOCITY-SPACE PN: Command a change in velocity direction
	var commanded_velocity_turn_rate = current_gain * los_rate
	
	# P-TERM: Proportional heading correction in velocity space
	var time_to_impact = calculate_time_to_impact()
	var heading_correction_gain = 3.0 + (current_gain * 0.02)
	if time_to_impact < 10.0:
		heading_correction_gain = 5.0 + (current_gain * 0.03)
	commanded_velocity_turn_rate += heading_error * heading_correction_gain
	
	# Apply turn rate limits
	commanded_velocity_turn_rate = clamp(commanded_velocity_turn_rate, -deg_to_rad(max_turn_rate), deg_to_rad(max_turn_rate))
	
	# Apply turn rate limits to the commanded turn
	commanded_velocity_turn_rate = clamp(commanded_velocity_turn_rate, -deg_to_rad(max_turn_rate), deg_to_rad(max_turn_rate))
	
	# ROTATE THE BODY to steer the velocity vector
	# The body needs to "lead" the velocity to turn it
	# We command the body to rotate, which will affect velocity through thrust
	rotation += commanded_velocity_turn_rate * delta
	
	# REALISTIC THRUST: Only thrust forward in the direction the torpedo is pointing
	var thrust_direction = Vector2.from_angle(rotation - PI/2)  # Convert Godot rotation to direction
	velocity_mps += thrust_direction * acceleration * delta
	
	# NO ALIGNMENT CODE - The torpedo points wherever it needs to for optimal thrust vectoring!
	# If we need 30° off-axis to catch a 12G target, so be it!
	# Against gentle targets, physics naturally minimizes the offset
	# Against aggressive targets, we maximize our lateral thrust component

func update_bias_debug():
	"""Debug function showing velocity-based measurement eliminates bias"""
	var current_time = time_since_launch
	
	# Log detailed angle analysis every N seconds
	if current_time - last_bias_debug_time >= debug_bias_interval:
		last_bias_debug_time = current_time
		
		print("\n[VELOCITY-MEASURED GUIDANCE] %s at %.1fs:" % [torpedo_id, current_time])
		
		# 1. Body orientation vs velocity
		var body_heading = rotation - PI/2
		var velocity_angle = velocity_mps.angle() if velocity_mps.length() > 0.1 else body_heading
		var alignment_error = atan2(sin(velocity_angle - body_heading), cos(velocity_angle - body_heading))
		
		print("  Body heading: %.4f rad (%.2f°)" % [body_heading, rad_to_deg(body_heading)])
		print("  Velocity angle: %.4f rad (%.2f°)" % [velocity_angle, rad_to_deg(velocity_angle)])
		print("  Body-Velocity offset: %.4f rad (%.2f°) <- THRUST VECTORING ANGLE" % [alignment_error, rad_to_deg(alignment_error)])
		
		# 2. Guidance calculations (now in velocity space)
		if target_node and is_instance_valid(target_node):
			var to_intercept = intercept_point - global_position
			var intercept_angle = to_intercept.angle()
			
			print("  To intercept angle: %.4f rad (%.2f°)" % [intercept_angle, rad_to_deg(intercept_angle)])
			
			# Heading error (now measured from velocity, not body)
			var heading_error = atan2(sin(intercept_angle - velocity_angle), cos(intercept_angle - velocity_angle))
			print("  VELOCITY-BASED ERROR: %.4f rad (%.2f°) <- Should converge to ZERO" % [heading_error, rad_to_deg(heading_error)])
			
			# Average error from history
			if angle_history.size() > 5:
				var sum_error = 0.0
				var sum_alignment = 0.0
				for entry in angle_history:
					sum_error += entry.heading_error
					if "velocity_heading" in entry and "body_heading" in entry:
						var align = atan2(sin(entry.velocity_heading - entry.body_heading), cos(entry.velocity_heading - entry.body_heading))
						sum_alignment += align
				var avg_error = sum_error / angle_history.size()
				var avg_alignment = sum_alignment / angle_history.size()
				print("  Average velocity error (last %d frames): %.4f rad (%.2f°)" % 
					[angle_history.size(), avg_error, rad_to_deg(avg_error)])
				print("  Average thrust vectoring angle: %.4f rad (%.2f°)" % [avg_alignment, rad_to_deg(avg_alignment)])
		
		print("")

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
		var estimated_time = sqrt(2.0 * distance_meters / acceleration)
		return estimated_time
		
	return distance_meters / closing_velocity

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
	
	# Calculate heading error (NOW FROM VELOCITY)
	var velocity_angle = velocity_mps.angle() if velocity_mps.length() > min_velocity_for_measurement else rotation - PI/2
	var los_vector = intercept_point - global_position
	var desired_heading = los_vector.angle()
	var heading_error = rad_to_deg(atan2(sin(desired_heading - velocity_angle), cos(desired_heading - velocity_angle)))
	
	# Calculate body-velocity offset (thrust vectoring angle)
	var body_heading = rotation - PI/2
	var alignment_error = rad_to_deg(atan2(sin(velocity_angle - body_heading), cos(velocity_angle - body_heading)))
	
	# Get time to impact
	var tti = calculate_time_to_impact()
	var tti_str = ""
	if tti < 100.0:
		tti_str = "TTI: %.1fs" % tti
	elif tti < INF:
		tti_str = "TTI: %.0fs" % tti
	else:
		tti_str = "TTI: ---"
	
	# Format error rate
	var err_rate_str = "ΔErr: %.1f°/s" % error_rate
	
	# Add time of flight
	var tof_str = "ToF: %.1fs" % time_since_launch
	
	# Format gain string
	var gain_str = "PN: %.0f" % current_gain
	
	# Add thrust vectoring angle
	var thrust_angle_str = "Thrust: %.1f°" % alignment_error
	
	# Calculate progress for additional debug info
	var current_distance_meters = global_position.distance_to(target_node.global_position) * WorldSettings.meters_per_pixel
	var progress = 1.0 - (current_distance_meters / initial_target_distance)
	if abs(progress - last_logged_progress) > 0.1:  # Log phase changes
		var phase = "Launch" if progress < 0.05 else "Mid-course" if progress < 0.70 else "Terminal"
		print("%s: Entering %s phase (%.0f%% complete)" % [torpedo_id, phase, progress * 100])
		last_logged_progress = progress
	
	print("%s: %.1f km/s | Tgt: %.1f km | Int: %.1f km | Err: %.1f° | %s | %s | %s | %s | %s" % 
		[torpedo_id, speed_kms, range_km, intercept_range_km, heading_error, err_rate_str, gain_str, tof_str, tti_str, thrust_angle_str])

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
		print("  - Body/velocity alignment at impact: %.1f°" % velocity_orientation_diff)
		
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
