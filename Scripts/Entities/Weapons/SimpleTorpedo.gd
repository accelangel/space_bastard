# Scripts/Entities/Weapons/SimpleTorpedo.gd
extends Area2D

# Proportional Navigation parameters
@export var navigation_constant: float = 4.0  # N (increased for better tracking)
@export var acceleration: float = 980.0       # 100G forward thrust
@export var max_turn_rate: float = 240.0      # degrees/second (increased)

# Debug settings
@export var debug_output: bool = true
@export var debug_los_line: bool = true       # Show line-of-sight to target

# Torpedo identity
var torpedo_id: String = ""
var faction: String = "friendly"
var target_node: Node2D = null
var launch_time: float = 0.0

# Physics state
var velocity_mps: Vector2 = Vector2.ZERO
var is_alive: bool = true
var marked_for_death: bool = false

# PN guidance state
var last_los_angle: float = 0.0
var first_frame: bool = true

# Visual elements
var los_line: Line2D = null

# Debug tracking
var last_debug_print: float = 0.0

func _ready():
	# Cap FPS for consistent debugging
	Engine.max_fps = 60
	
	# Generate unique ID
	torpedo_id = "torp_%d" % [get_instance_id()]
	launch_time = Time.get_ticks_msec() / 1000.0
	
	# Add to groups
	add_to_group("torpedoes")
	add_to_group("combat_entities")
	
	# Store identity
	set_meta("torpedo_id", torpedo_id)
	set_meta("faction", faction)
	set_meta("entity_type", "torpedo")
	
	# Connect collision
	area_entered.connect(_on_area_entered)
	
	# Start animation if present
	var sprite = get_node_or_null("AnimatedSprite2D")
	if sprite:
		sprite.play()
	
	# Setup visual debugging
	setup_debug_line()
	
	print("Torpedo %s launched - TRUE PROPORTIONAL NAVIGATION" % torpedo_id)

func setup_debug_line():
	"""Setup line-of-sight visualization"""
	if not debug_los_line:
		return
		
	los_line = get_node_or_null("TrajectoryLine")  # Reuse the same Line2D node
	
	if los_line:
		los_line.width = 1.0
		los_line.default_color = Color.RED
		los_line.antialiased = true
		los_line.z_index = 5
		los_line.top_level = true
		print("Torpedo %s: LOS line configured" % torpedo_id)

func _physics_process(delta):
	if marked_for_death or not is_alive or not target_node:
		return
	
	# Validate target still exists
	if not is_instance_valid(target_node):
		mark_for_destruction("lost_target")
		return
	
	# Get target state
	var target_pos = target_node.global_position
	var target_velocity = Vector2.ZERO
	if target_node.has_method("get_velocity_mps"):
		target_velocity = target_node.get_velocity_mps()
	
	# PROPORTIONAL NAVIGATION
	perform_proportional_navigation(delta, target_pos, target_velocity)
	
	# Always accelerate forward (accounting for 90-degree sprite rotation)
	var thrust_direction = Vector2.from_angle(rotation - PI/2)
	velocity_mps += thrust_direction * acceleration * delta
	
	# Update position
	var velocity_pixels = velocity_mps / WorldSettings.meters_per_pixel
	global_position += velocity_pixels * delta
	
	# Update visual debugging
	if debug_los_line and los_line:
		update_los_line(target_pos)
	
	# Debug output
	if debug_output:
		update_debug_output(target_pos)
	
	# Check bounds
	check_world_bounds()

func perform_proportional_navigation(delta: float, target_pos: Vector2, target_velocity: Vector2):
	"""Proportional navigation with continuous correction and sanity checks"""
	
	# Get LOS vector and angle
	var los_vector = target_pos - global_position
	var range_m = los_vector.length() * WorldSettings.meters_per_pixel
	var los_angle = los_vector.angle()
	
	# Initialize on first frame
	if first_frame:
		last_los_angle = los_angle
		first_frame = false
		rotation = los_angle + PI/2
		return
	
	# DYNAMIC TERMINAL GUIDANCE - Scale with speed
	var speed = velocity_mps.length()
	var terminal_range = max(500000.0, speed * 10.0)  # At least 500km or 10 seconds
	
	if range_m < terminal_range:
		# Simple pursuit when close
		var desired_angle = los_angle + PI/2
		var angle_error = angle_difference(desired_angle, rotation)
		
		# SANITY CHECK - Never command more than 90° turn
		if abs(angle_error) > deg_to_rad(90):
			print("WARNING: Terminal guidance wanted %.1f° turn! Clamping." % rad_to_deg(angle_error))
			angle_error = sign(angle_error) * deg_to_rad(90)
		
		var turn_rate = clamp(angle_error * 10.0, -deg_to_rad(max_turn_rate), deg_to_rad(max_turn_rate))
		rotation += turn_rate * delta
		return
	
	# PROPORTIONAL NAVIGATION
	var raw_los_rate = angle_difference(los_angle, last_los_angle) / delta
	
	# DEBUG: Catch suspicious LOS rate
	if abs(raw_los_rate) > deg_to_rad(100):
		print("SUSPICIOUS LOS RATE: %.1f°/s at range %.1f km" % [rad_to_deg(raw_los_rate), range_m/1000.0])
		print("  Last LOS: %.1f°, Current LOS: %.1f°" % [rad_to_deg(last_los_angle), rad_to_deg(los_angle)])
	
	last_los_angle = los_angle
	
	# Cap LOS rate to prevent instability
	var los_rate = clamp(raw_los_rate, -deg_to_rad(45.0), deg_to_rad(45.0))
	
	# Basic PN guidance
	var commanded_turn_rate = navigation_constant * los_rate
	
	# ALWAYS correct heading errors - no threshold!
	var current_heading = rotation - PI/2
	var heading_error = angle_difference(los_angle, current_heading)
	
	# Progressive correction that's always active
	var correction_gain = 1.0  # Always at least 1x correction
	if abs(heading_error) > deg_to_rad(10.0):
		correction_gain = 2.0
	if abs(heading_error) > deg_to_rad(30.0):
		correction_gain = 4.0
	
	# Add heading correction
	commanded_turn_rate += heading_error * correction_gain
	
	# SANITY CHECK - Never command insane turns
	if abs(commanded_turn_rate) > deg_to_rad(max_turn_rate):
		var commanded_deg = rad_to_deg(commanded_turn_rate)
		if abs(commanded_deg) > max_turn_rate * 1.5:  # Way too much
			print("WARNING: PN commanded %.1f°/s turn! (LOS rate: %.1f°/s, Head err: %.1f°)" % 
				[commanded_deg, rad_to_deg(los_rate), rad_to_deg(heading_error)])
	
	# Apply turn rate limit
	commanded_turn_rate = clamp(commanded_turn_rate, -deg_to_rad(max_turn_rate), deg_to_rad(max_turn_rate))
	
	# Apply rotation
	rotation += commanded_turn_rate * delta
	
	# FINAL SANITY CHECK - Don't let torpedo point backwards
	var velocity_angle = velocity_mps.angle() + PI/2
	var pointing_error = abs(angle_difference(rotation, velocity_angle))
	if pointing_error > deg_to_rad(90):
		print("ERROR: Torpedo pointing %.1f° from velocity! Something is very wrong!" % rad_to_deg(pointing_error))
		# Force it to point somewhat forward
		rotation = velocity_angle + sign(angle_difference(rotation, velocity_angle)) * deg_to_rad(85)

func angle_difference(to: float, from: float) -> float:
	var diff = to - from
	while diff > PI:
		diff -= TAU
	while diff < -PI:
		diff += TAU
	return diff

func update_los_line(target_pos: Vector2):
	"""Update line-of-sight visualization"""
	if not los_line:
		return
	
	los_line.clear_points()
	los_line.add_point(global_position)
	los_line.add_point(target_pos)
	
	# Scale line width with zoom
	var cam = get_viewport().get_camera_2d()
	if cam:
		los_line.width = 1.0 / cam.zoom.x

func update_debug_output(target_pos: Vector2):
	"""Print debug info once per second"""
	var current_time = Time.get_ticks_msec() / 1000.0
	if current_time - last_debug_print < 1.0:
		return
	last_debug_print = current_time
	
	var speed_kms = velocity_mps.length() / 1000.0
	var range_km = (target_pos - global_position).length() * WorldSettings.meters_per_pixel / 1000.0
	var time_to_impact = range_km * 1000.0 / max(velocity_mps.length(), 1.0)
	
	# Calculate heading error
	var los_angle = (target_pos - global_position).angle()
	var current_heading = rotation - PI/2
	var heading_error = rad_to_deg(angle_difference(los_angle, current_heading))
	
	# Determine guidance mode based on dynamic terminal range
	var terminal_range_km = max(500.0, velocity_mps.length() * 10.0 / 1000.0)
	var mode = "PN"
	if range_km < terminal_range_km:
		mode = "TERM"
	
	print("Torpedo %s: %s | %.1f km/s | %.1f km | %.1fs | Err: %.1f°" % 
		[torpedo_id, mode, speed_kms, range_km, time_to_impact, heading_error])

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
