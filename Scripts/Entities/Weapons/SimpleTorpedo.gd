# Scripts/Entities/Weapons/SimpleTorpedo.gd - BANG-BANG CONTROL
# Dead simple: Turn toward target at fixed rate, thrust forward
extends Area2D

# Static counter for sequential torpedo naming
static var torpedo_counter: int = 0

# Core parameters
@export var acceleration: float = 980.0       # 100G forward thrust
@export var turn_rate_deg_per_s: float = 100.0  # Fixed turn rate for bang-bang control
@export var error_threshold_deg: float = 1.0    # Don't turn if error smaller than this

# Terminal phase parameters
@export var terminal_phase_threshold: float = 0.85  # Start terminal at 85% of journey

# Intercept calculation
@export var intercept_iterations: int = 10    # Iterations for intercept calculation

# Debug settings
@export var debug_output: bool = true
@export var debug_interval: float = 1.0

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
var initial_target_distance: float = 0.0
var time_since_launch: float = 0.0

# Terminal phase state
var is_terminal_phase: bool = false

# Tracking
var closest_approach_distance: float = INF
var closest_approach_time: float = 0.0

# Visual elements
var trajectory_line: Line2D = null

# Debug tracking
var last_debug_print: float = 0.0
var last_logged_progress: float = -1.0

func _ready():
	Engine.max_fps = 60
	
	# Generate sequential torpedo ID
	torpedo_counter += 1
	torpedo_id = "Torp_%d" % torpedo_counter
	
	print("[BANG-BANG] %s: Initialized" % torpedo_id)
	print("  - Turn rate: %.0f°/s" % turn_rate_deg_per_s)
	print("  - Error threshold: %.1f°" % error_threshold_deg)
	print("  - Terminal phase: >%.0f%%" % (terminal_phase_threshold * 100))
	
	add_to_group("torpedoes")
	add_to_group("combat_entities")
	
	set_meta("torpedo_id", torpedo_id)
	set_meta("faction", faction)
	set_meta("entity_type", "torpedo")
	
	# Connect collision signal
	area_entered.connect(_on_area_entered)
	
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

func _physics_process(delta):
	if marked_for_death or not is_alive or not target_node:
		return
	
	if not is_instance_valid(target_node):
		mark_for_destruction("lost_target")
		return
	
	# Initialize on first frame
	if initial_target_distance <= 0 and target_node:
		initial_target_distance = global_position.distance_to(target_node.global_position) * WorldSettings.meters_per_pixel
		var range_km = initial_target_distance / 1000.0
		print("%s: Launch - range %.1f km" % [torpedo_id, range_km])
	
	time_since_launch += delta
	
	# Track closest approach
	update_closest_approach()
	
	# Calculate intercept point
	calculate_intercept()
	
	# BANG-BANG CONTROL
	apply_bang_bang_control(delta)
	
	# THRUST MANAGEMENT
	apply_thrust(delta)
	
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

func apply_bang_bang_control(delta):
	"""Simple bang-bang control - turn at fixed rate toward intercept"""
	
	# Get current velocity heading (where we're going)
	var velocity_angle: float
	if velocity_mps.length() > 10.0:  # Only use velocity angle if moving
		velocity_angle = velocity_mps.angle()
	else:
		velocity_angle = rotation - PI/2  # Use body angle at launch
	
	# Get desired heading to intercept
	var to_intercept = intercept_point - global_position
	var desired_angle = to_intercept.angle()
	
	# Calculate error (shortest angular distance)
	var error = atan2(sin(desired_angle - velocity_angle), cos(desired_angle - velocity_angle))
	var error_deg = rad_to_deg(error)
	
	# BANG-BANG CONTROL
	if abs(error_deg) > error_threshold_deg:
		# Turn at fixed rate in the correct direction
		var turn_rate_rad = deg_to_rad(turn_rate_deg_per_s)
		rotation += sign(error) * turn_rate_rad * delta
	# else: don't turn - we're close enough

func apply_thrust(delta):
	"""Apply thrust - always during cruise, only when steering during terminal"""
	
	# Calculate progress
	var current_distance = global_position.distance_to(target_node.global_position) * WorldSettings.meters_per_pixel
	var progress = 1.0 - (current_distance / initial_target_distance)
	progress = clamp(progress, 0.0, 1.0)
	
	# Check terminal phase
	is_terminal_phase = progress > terminal_phase_threshold
	
	# Get current error to determine if we're steering
	var velocity_angle = velocity_mps.angle() if velocity_mps.length() > 10.0 else rotation - PI/2
	var desired_angle = (intercept_point - global_position).angle()
	var error = atan2(sin(desired_angle - velocity_angle), cos(desired_angle - velocity_angle))
	var error_deg = abs(rad_to_deg(error))
	
	# Determine if we should thrust
	var should_thrust = true
	
	if is_terminal_phase:
		# In terminal: Only thrust if we're actively correcting (error > threshold)
		# If error is small, we're on target - coast
		should_thrust = error_deg > error_threshold_deg
		
		# Log terminal phase entry once
		if abs(progress - terminal_phase_threshold) < 0.01:
			print("%s: TERMINAL PHASE at %.1f km/s - thrust only when steering" % 
				[torpedo_id, velocity_mps.length() / 1000.0])
	
	# Apply thrust
	if should_thrust:
		var thrust_direction = Vector2.from_angle(rotation - PI/2)
		velocity_mps += thrust_direction * acceleration * delta

func calculate_intercept():
	"""Calculate where to aim based on target motion"""
	if not target_node or not is_instance_valid(target_node):
		return
	
	var target_velocity = Vector2.ZERO
	if target_node.has_method("get_velocity_mps"):
		target_velocity = target_node.get_velocity_mps()
	
	# Convert to pixels
	var target_vel_pixels = target_velocity / WorldSettings.meters_per_pixel
	var target_pos = target_node.global_position
	
	# Simple iterative intercept calculation
	intercept_point = target_pos
	
	for iteration in range(intercept_iterations):
		var to_intercept = intercept_point - global_position
		var distance_meters = to_intercept.length() * WorldSettings.meters_per_pixel
		
		# Estimate time to reach intercept
		var current_speed = velocity_mps.length()
		var time_to_intercept: float
		
		if current_speed < 100.0:
			# Use kinematic equation for acceleration
			time_to_intercept = sqrt(2.0 * distance_meters / acceleration)
		else:
			# Simple linear estimate
			time_to_intercept = distance_meters / current_speed
		
		time_to_intercept = max(time_to_intercept, 0.1)
		
		# Update intercept based on target motion
		var new_intercept = target_pos + target_vel_pixels * time_to_intercept
		
		# Check convergence
		if new_intercept.distance_to(intercept_point) < 1.0:
			break
		
		intercept_point = new_intercept

func update_trajectory_visualization():
	if not trajectory_line:
		return
	
	trajectory_line.clear_points()
	
	# Color based on phase
	if is_terminal_phase:
		trajectory_line.default_color = Color.CYAN
	else:
		trajectory_line.default_color = Color.ORANGE
	
	# Draw line to intercept
	trajectory_line.add_point(global_position)
	trajectory_line.add_point(intercept_point)

func update_debug_output():
	var current_time = Time.get_ticks_msec() / 1000.0
	if current_time - last_debug_print < debug_interval:
		return
	last_debug_print = current_time
	
	if not target_node:
		return
	
	var speed_kms = velocity_mps.length() / 1000.0
	var range_km = global_position.distance_to(target_node.global_position) * WorldSettings.meters_per_pixel / 1000.0
	
	# Calculate heading error
	var velocity_angle = velocity_mps.angle() if velocity_mps.length() > 10.0 else rotation - PI/2
	var desired_angle = (intercept_point - global_position).angle()
	var error = atan2(sin(desired_angle - velocity_angle), cos(desired_angle - velocity_angle))
	var error_deg = rad_to_deg(error)
	
	# Calculate body-velocity alignment
	var body_angle = rotation - PI/2
	var alignment_error = atan2(sin(velocity_angle - body_angle), cos(velocity_angle - body_angle))
	var alignment_deg = rad_to_deg(alignment_error)
	
	# Phase info
	var current_distance = global_position.distance_to(target_node.global_position) * WorldSettings.meters_per_pixel
	var progress = 1.0 - (current_distance / initial_target_distance)
	
	# Log phase changes
	if abs(progress - last_logged_progress) > 0.1:
		var phase = "Launch" if progress < 0.05 else "Cruise" if progress < terminal_phase_threshold else "Terminal"
		print("%s: %s phase (%.0f%%)" % [torpedo_id, phase, progress * 100])
		last_logged_progress = progress
	
	var phase_str = "TERM" if is_terminal_phase else "CRSE"
	
	print("%s: %.1f km/s | %.1f km | Err: %.1f° | Align: %.1f° | %s" % 
		[torpedo_id, speed_kms, range_km, error_deg, alignment_deg, phase_str])

func update_closest_approach():
	if not target_node:
		return
	
	var current_distance = global_position.distance_to(target_node.global_position)
	var current_distance_meters = current_distance * WorldSettings.meters_per_pixel
	
	if current_distance_meters < closest_approach_distance:
		closest_approach_distance = current_distance_meters
		closest_approach_time = time_since_launch

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
		
		# Calculate final alignment
		var velocity_angle = velocity_mps.angle()
		var body_angle = rotation - PI/2
		var alignment_diff = rad_to_deg(atan2(sin(velocity_angle - body_angle), cos(velocity_angle - body_angle)))
		
		print("SUCCESS [%s]: HIT %s!" % [torpedo_id, area.name])
		print("  - Impact: %.1fs at %.1f km" % [time_since_launch, closest_approach_distance / 1000.0])
		print("  - Speed: %.1f km/s" % (velocity_mps.length() / 1000.0))
		print("  - Alignment: %.1f°" % alignment_diff)
		
		if area.has_method("mark_for_destruction"):
			area.mark_for_destruction("torpedo_impact")
		
		mark_for_destruction("target_impact")

func mark_for_destruction(reason: String):
	if marked_for_death:
		return
	
	marked_for_death = true
	is_alive = false
	
	if reason == "out_of_bounds" and closest_approach_distance < INF:
		print("MISS [%s]: %s | Closest: %.1f km at %.1fs" % 
			[torpedo_id, reason, closest_approach_distance / 1000.0, closest_approach_time])
	elif reason == "target_impact":
		print("HIT [%s]: Target destroyed" % torpedo_id)
	else:
		print("LOST [%s]: %s" % [torpedo_id, reason])
	
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
	if target_node:
		print("  - Target: %s" % target_node.name)

func set_launcher(launcher_ship: Node2D):
	if "faction" in launcher_ship:
		faction = launcher_ship.faction

func get_velocity_mps() -> Vector2:
	return velocity_mps

# Compatibility stubs
func set_launch_side(_side: int):
	pass

func set_flight_plan(_plan: String, _data: Dictionary = {}):
	pass
