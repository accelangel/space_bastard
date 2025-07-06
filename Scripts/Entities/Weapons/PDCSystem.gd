# Scripts/Entities/Weapons/PDCSystem.gd - DEBUG VERSION TO FIND THE BUG
extends Node2D
class_name PDCSystem

# PDC Configuration
@export var fire_rate: float = 200.0  # Bullets per second (max capability)
@export var bullet_velocity_mps: float = 300.0
@export var stream_length: int = 20  # Bullets per stream
@export var stream_spread_degrees: float = 1.5  # Slight cone angle for the stream
@export var engagement_range_meters: float = 8000.0  # Start engaging at 8km
@export var min_intercept_distance_meters: float = 500.0  # Don't shoot if torpedo is too close

# DEBUG FLAGS
@export var debug_enabled: bool = true
@export var debug_detailed: bool = false
@export var debug_vectors: bool = true

# Preload bullet scene
var bullet_scene: PackedScene = preload("res://Scenes/PDCBullet.tscn")

# References
var parent_ship: Node2D
var sensor_system: SensorSystem

# Firing control
var fire_timer: float = 0.0
var bullet_interval: float = 0.005  # 5ms between bullets in a stream (200 rounds/sec)

# Stream tracking
var active_streams: Array = []  # Currently firing streams
var tracked_torpedoes: Dictionary = {}  # torpedo -> InterceptData

# Statistics
var torpedoes_intercepted: int = 0
var shots_fired: int = 0

# DEBUG COUNTERS
var debug_frame_count: int = 0
var debug_last_fire_info: Dictionary = {}

class InterceptData:
	var torpedo: Node2D
	var last_intercept_time: float = -999.0
	var intercept_count: int = 0
	var predicted_impact_time: float = INF
	var current_stream: StreamData = null  # Active stream targeting this torpedo

class StreamData:
	var target_torpedo: Node2D
	var base_direction: Vector2
	var bullets_fired: int = 0
	var start_time: float
	var lead_calculation: Dictionary  # Stores lead angle and prediction data

func _ready():
	parent_ship = get_parent()
	
	# Find sensor system on parent
	if parent_ship:
		sensor_system = parent_ship.get_node_or_null("SensorSystem")
		if not sensor_system:
			print("PDCSystem: No sensor system found on parent ship!")
	
	var ship_name: String = "unknown"
	if parent_ship:
		ship_name = parent_ship.name
	print("=== PDC DEBUG VERSION INITIALIZED ===")
	print("PDCSystem initialized on ", ship_name)
	print("  Expanse-style stream firing: ON")
	print("  Stream length: ", stream_length, " rounds")
	print("  Engagement range: ", engagement_range_meters / 1000.0, " km")
	print("  DEBUG MODE: ", debug_enabled)

func _physics_process(delta):
	debug_frame_count += 1
	fire_timer += delta
	
	if not sensor_system:
		return
	
	# Update torpedo tracking
	update_torpedo_tracking()
	
	# Manage active streams
	update_active_streams()
	
	# Start new streams for unengaged torpedoes
	start_new_streams()
	
	# Fire bullets for all active streams
	if fire_timer >= bullet_interval:
		fire_stream_bullets()
		fire_timer = 0.0

func update_torpedo_tracking():
	var current_torpedoes = sensor_system.get_all_enemy_torpedoes()
	var current_time = Time.get_ticks_msec() / 1000.0
	
	# DEBUG: Log torpedo count changes
	if debug_enabled and current_torpedoes.size() != tracked_torpedoes.size():
		print("DEBUG: Torpedo count changed from ", tracked_torpedoes.size(), " to ", current_torpedoes.size())
	
	# Remove destroyed torpedoes
	var to_remove = []
	for torpedo in tracked_torpedoes:
		if not is_instance_valid(torpedo) or torpedo not in current_torpedoes:
			to_remove.append(torpedo)
	for torpedo in to_remove:
		tracked_torpedoes.erase(torpedo)
	
	# Add new torpedoes
	for torpedo in current_torpedoes:
		if torpedo not in tracked_torpedoes:
			tracked_torpedoes[torpedo] = InterceptData.new()
			tracked_torpedoes[torpedo].torpedo = torpedo
			if debug_enabled:
				print("DEBUG: New torpedo tracked at ", torpedo.global_position)
	
	# Update intercept data for all torpedoes
	for torpedo in tracked_torpedoes:
		update_intercept_data(tracked_torpedoes[torpedo], current_time)

func update_intercept_data(data: InterceptData, current_time: float):
	var torpedo = data.torpedo
	if not is_instance_valid(torpedo):
		return
	
	# Get torpedo kinematics
	var torpedo_pos = torpedo.global_position
	var torpedo_vel = get_torpedo_velocity(torpedo)
	var to_torpedo = torpedo_pos - global_position
	var distance_meters = to_torpedo.length() * WorldSettings.meters_per_pixel
	
	# Calculate predicted impact time
	if torpedo_vel.length() > 10.0:
		var closing_speed = -torpedo_vel.dot(to_torpedo.normalized())
		if closing_speed > 0:
			data.predicted_impact_time = current_time + (distance_meters / closing_speed)
		else:
			data.predicted_impact_time = INF
	else:
		data.predicted_impact_time = INF

func update_active_streams():
	for i in range(active_streams.size() - 1, -1, -1):
		var stream = active_streams[i]
		
		# Remove completed or invalid streams
		if stream.bullets_fired >= stream_length or not is_instance_valid(stream.target_torpedo):
			if debug_enabled:
				print("DEBUG: Stream completed. Bullets fired: ", stream.bullets_fired, "/", stream_length)
			active_streams.remove_at(i)
			# Mark torpedo as no longer having active stream
			if tracked_torpedoes.has(stream.target_torpedo):
				tracked_torpedoes[stream.target_torpedo].current_stream = null

func start_new_streams():
	var current_time = Time.get_ticks_msec() / 1000.0
	
	# Find highest priority torpedo without active stream
	var best_target = null
	var best_priority = -1.0
	
	for data in tracked_torpedoes.values():
		if data.current_stream != null:
			continue  # Already has active stream
			
		var torpedo = data.torpedo
		if not should_engage(torpedo, data):
			continue
		
		# Calculate priority
		var priority = calculate_torpedo_priority(data)
		if priority > best_priority:
			best_priority = priority
			best_target = data
	
	# Start stream for best target
	if best_target:
		var stream = create_new_stream(best_target)
		if stream:
			active_streams.append(stream)
			best_target.current_stream = stream
			best_target.last_intercept_time = current_time
			
			if debug_enabled:
				print("DEBUG: New stream started for torpedo at ", best_target.torpedo.global_position)
				print("  Stream base direction: ", stream.base_direction)
				print("  Lead calculation: ", stream.lead_calculation)

func create_new_stream(data: InterceptData) -> StreamData:
	var torpedo = data.torpedo
	var torpedo_pos = torpedo.global_position
	var torpedo_vel = get_torpedo_velocity(torpedo)
	
	# Calculate lead prediction
	var lead_data = calculate_stream_lead(torpedo_pos, torpedo_vel)
	
	if not lead_data.has("direction"):
		if debug_enabled:
			print("DEBUG: Failed to calculate lead for torpedo at ", torpedo_pos)
		return null
	
	var stream = StreamData.new()
	stream.target_torpedo = torpedo
	stream.base_direction = lead_data.direction
	stream.lead_calculation = lead_data
	stream.start_time = Time.get_ticks_msec() / 1000.0
	
	# DEBUG: Detailed stream creation info
	if debug_detailed:
		print("=== STREAM CREATION DEBUG ===")
		print("  Torpedo pos: ", torpedo_pos)
		print("  Torpedo vel: ", torpedo_vel)
		print("  PDC pos: ", global_position)
		print("  Lead direction: ", lead_data.direction)
		print("  Distance: ", lead_data.distance, " meters")
		print("  Travel time: ", lead_data.travel_time, " seconds")
	
	return stream

func calculate_stream_lead(torpedo_pos: Vector2, torpedo_vel: Vector2) -> Dictionary:
	var to_torpedo = torpedo_pos - global_position
	var distance = to_torpedo.length()
	var distance_meters = distance * WorldSettings.meters_per_pixel
	
	# Basic time to impact
	var bullet_travel_time = distance_meters / bullet_velocity_mps
	
	# Predict where torpedo will be when our bullets could reach it
	var predicted_pos = torpedo_pos + (torpedo_vel * bullet_travel_time)
	var lead_direction = (predicted_pos - global_position).normalized()
	
	# DEBUG: Log the calculation steps
	if debug_vectors:
		print("=== LEAD CALCULATION DEBUG ===")
		print("  PDC position: ", global_position)
		print("  Torpedo position: ", torpedo_pos)
		print("  Torpedo velocity: ", torpedo_vel)
		print("  Vector to torpedo: ", to_torpedo)
		print("  Distance (pixels): ", distance)
		print("  Distance (meters): ", distance_meters)
		print("  Bullet travel time: ", bullet_travel_time)
		print("  Predicted torpedo pos: ", predicted_pos)
		print("  Lead direction: ", lead_direction)
		print("  Lead angle (degrees): ", rad_to_deg(lead_direction.angle()))
	
	# Don't shoot backwards!
	var ship_vel = get_ship_velocity()
	if ship_vel.length() > 50.0:
		var angle_to_ship_direction = lead_direction.angle_to(ship_vel.normalized())
		if debug_vectors:
			print("  Ship velocity: ", ship_vel)
			print("  Angle to ship direction: ", rad_to_deg(angle_to_ship_direction))
		
		# If we're trying to shoot more than 90 degrees away from ship direction, just shoot at current position
		if abs(angle_to_ship_direction) > PI/2:
			lead_direction = to_torpedo.normalized()
			if debug_vectors:
				print("  ADJUSTED: Shooting at current position instead")
				print("  New direction: ", lead_direction)
	
	return {
		"direction": lead_direction,
		"distance": distance_meters,
		"travel_time": bullet_travel_time
	}

func fire_stream_bullets():
	for stream in active_streams:
		if stream.bullets_fired >= stream_length:
			continue
		
		# Calculate bullet direction with slight spread
		var spread_progress = float(stream.bullets_fired) / float(stream_length)
		var spread_angle = sin(spread_progress * PI) * deg_to_rad(stream_spread_degrees)
		
		# Alternate spread direction for better coverage
		if stream.bullets_fired % 2 == 1:
			spread_angle *= -1
		
		var bullet_direction = stream.base_direction.rotated(spread_angle)
		
		# DEBUG: Log every bullet fired
		if debug_detailed:
			print("=== BULLET FIRE DEBUG ===")
			print("  Stream bullet #", stream.bullets_fired + 1, "/", stream_length)
			print("  Base direction: ", stream.base_direction)
			print("  Spread angle: ", rad_to_deg(spread_angle))
			print("  Final direction: ", bullet_direction)
			print("  Final angle: ", rad_to_deg(bullet_direction.angle()))
		
		# Store debug info for this fire
		debug_last_fire_info = {
			"bullet_direction": bullet_direction,
			"base_direction": stream.base_direction,
			"spread_angle": spread_angle,
			"target_pos": stream.target_torpedo.global_position if is_instance_valid(stream.target_torpedo) else Vector2.ZERO,
			"pdc_pos": global_position,
			"frame": debug_frame_count
		}
		
		# Fire the bullet
		fire_bullet(bullet_direction)
		stream.bullets_fired += 1

func calculate_torpedo_priority(data: InterceptData) -> float:
	var torpedo = data.torpedo
	var to_torpedo = torpedo.global_position - global_position
	var distance_meters = to_torpedo.length() * WorldSettings.meters_per_pixel
	
	# Closer = higher priority
	var distance_factor = 1.0 - (distance_meters / engagement_range_meters)
	
	# Faster approach = higher priority
	var torpedo_vel = get_torpedo_velocity(torpedo)
	var closing_speed = -torpedo_vel.dot(to_torpedo.normalized())
	var speed_factor = clamp(closing_speed / 200.0, 0.0, 1.0)
	
	return distance_factor * 2.0 + speed_factor

func should_engage(torpedo: Node2D, _data: InterceptData) -> bool:
	if not torpedo or not is_instance_valid(torpedo):
		return false
	
	var to_torpedo = torpedo.global_position - global_position
	var distance_meters = to_torpedo.length() * WorldSettings.meters_per_pixel
	
	# Check range
	if distance_meters > engagement_range_meters or distance_meters < min_intercept_distance_meters:
		if debug_enabled and debug_frame_count % 60 == 0:  # Only log occasionally
			print("DEBUG: Torpedo out of range. Distance: ", distance_meters, " meters")
		return false
	
	# Only engage if torpedo is actually approaching
	var torpedo_vel = get_torpedo_velocity(torpedo)
	var closing_speed = -torpedo_vel.dot(to_torpedo.normalized())
	
	if debug_enabled and debug_frame_count % 60 == 0:
		print("DEBUG: Torpedo closing speed: ", closing_speed, " m/s")
	
	# Must be approaching at reasonable speed
	return closing_speed > 10.0

func fire_bullet(direction: Vector2):
	if not bullet_scene:
		return
	
	var bullet = bullet_scene.instantiate()
	get_tree().root.add_child(bullet)
	
	# Set bullet properties
	bullet.global_position = global_position
	
	# Calculate bullet velocity in world space
	var ship_velocity_mps = get_ship_velocity()
	var bullet_velocity_world = (direction * bullet_velocity_mps) + ship_velocity_mps
	var bullet_velocity_pixels = bullet_velocity_world / WorldSettings.meters_per_pixel
	
	# DEBUG: Log bullet creation
	if debug_vectors:
		print("=== BULLET CREATION DEBUG ===")
		print("  Bullet position: ", bullet.global_position)
		print("  Fire direction: ", direction)
		print("  Fire direction angle: ", rad_to_deg(direction.angle()))
		print("  Ship velocity (m/s): ", ship_velocity_mps)
		print("  Bullet velocity (m/s): ", bullet_velocity_world)
		print("  Bullet velocity (pixels/s): ", bullet_velocity_pixels)
		print("  Bullet velocity angle: ", rad_to_deg(bullet_velocity_pixels.angle()))
		
		# Check if we're shooting backwards relative to target
		if debug_last_fire_info.has("target_pos"):
			var to_target = debug_last_fire_info.target_pos - global_position
			var dot_product = direction.dot(to_target.normalized())
			print("  Dot product (direction vs to_target): ", dot_product)
			if dot_product < 0:
				print("  *** WARNING: SHOOTING BACKWARDS! ***")
				print("  Direction: ", direction)
				print("  To target: ", to_target.normalized())
	
	if bullet.has_method("set_velocity"):
		bullet.set_velocity(bullet_velocity_pixels)
	
	# Set faction
	if parent_ship and "faction" in parent_ship:
		if bullet.has_method("set_faction"):
			bullet.set_faction(parent_ship.faction)
	
	# Connect to bullet's destruction signal
	if bullet.has_signal("hit_target"):
		bullet.hit_target.connect(_on_torpedo_intercepted)
	
	shots_fired += 1

func get_torpedo_velocity(torpedo: Node2D) -> Vector2:
	if torpedo.has_method("get_velocity_mps"):
		return torpedo.get_velocity_mps()
	elif "velocity_mps" in torpedo:
		return torpedo.velocity_mps
	return Vector2.ZERO

func get_ship_velocity() -> Vector2:
	if parent_ship and parent_ship.has_method("get_velocity_mps"):
		return parent_ship.get_velocity_mps()
	return Vector2.ZERO

func _on_torpedo_intercepted():
	torpedoes_intercepted += 1
	print("=== TORPEDO INTERCEPTED! Total intercepted: ", torpedoes_intercepted, " ===")

func get_debug_info() -> String:
	var tracking = tracked_torpedoes.size()
	var streams = active_streams.size()
	
	return "PDC: %d shots | %d intercepts | Tracking: %d | Active streams: %d" % [
		shots_fired, torpedoes_intercepted, tracking, streams
	]

# DEBUG FUNCTIONS
func print_current_state():
	print("=== PDC STATE DEBUG ===")
	print("  Tracked torpedoes: ", tracked_torpedoes.size())
	print("  Active streams: ", active_streams.size())
	print("  Last fire info: ", debug_last_fire_info)
	print("  PDC position: ", global_position)
	print("  PDC rotation: ", rotation)

func toggle_debug():
	debug_enabled = !debug_enabled
	print("PDC Debug: ", debug_enabled)

func toggle_detailed_debug():
	debug_detailed = !debug_detailed
	print("PDC Detailed Debug: ", debug_detailed)

func toggle_vector_debug():
	debug_vectors = !debug_vectors
	print("PDC Vector Debug: ", debug_vectors)
