# Scripts/Entities/Weapons/PointDefenseCannon.gd
extends Node2D
class_name PointDefenseCannon

# Point defense settings
@export var detection_range_meters: float = 500.0  # How far it can detect threats
@export var firing_range_meters: float = 400.0    # How far it can shoot
@export var rotation_speed: float = 5.0           # How fast turret rotates (rad/s)
@export var fire_rate: float = 10.0               # Shots per second
@export var accuracy: float = 0.9                 # Hit chance (0.0 to 1.0)
@export var reaction_time: float = 0.2            # Delay before engaging new target

# Internal state
var current_target: EntityManager.EntityData = null
var last_shot_time: float = 0.0
var target_lock_time: float = 0.0
var current_rotation: float = 0.0
var owner_ship: BaseShip = null
var cannon_id: String

# Visual components (to be set up in scene)
@onready var turret_sprite: Sprite2D = $TurretSprite
@onready var barrel_sprite: Sprite2D = $TurretSprite/BarrelSprite

# Performance optimization
var last_scan_time: float = 0.0
var scan_interval: float = 0.1  # Scan for targets every 0.1 seconds
var firing_interval: float

func _ready():
	cannon_id = name + "_" + str(get_instance_id())
	firing_interval = 1.0 / fire_rate
	
	# Find our owner ship
	owner_ship = _find_owner_ship()
	if not owner_ship:
		push_error("PointDefenseCannon must be child of a BaseShip")
		return
	
	print("Point Defense Cannon initialized on ", owner_ship.name)

func _physics_process(delta):
	if not owner_ship:
		return
	
	var current_time = Time.get_ticks_msec() / 1000.0
	
	# Scan for threats periodically
	if current_time - last_scan_time >= scan_interval:
		_scan_for_threats()
		last_scan_time = current_time
	
	# Update current target
	_update_target_tracking(delta)
	
	# Fire if we have a valid target
	if current_target and _can_fire():
		_fire_at_target()

func _scan_for_threats():
	var ship_position = owner_ship.global_position
	var detection_range_pixels = detection_range_meters / WorldSettings.meters_per_pixel
	
	# Get all torpedoes in range
	var potential_threats = EntityManager.get_entities_in_radius(
		ship_position,
		detection_range_pixels,
		[EntityManager.EntityType.TORPEDO, EntityManager.EntityType.MISSILE],
		[],  # Any faction
		[EntityManager.EntityState.DESTROYED, EntityManager.EntityState.CLEANUP]
	)
	
	# Filter out friendly torpedoes
	var hostile_threats = []
	for threat in potential_threats:
		if _is_hostile_threat(threat):
			hostile_threats.append(threat)
	
	# Find the closest, most dangerous threat
	var best_target = _select_best_target(hostile_threats)
	
	# Switch targets if we found a better one
	if best_target and (not current_target or _is_better_target(best_target, current_target)):
		_acquire_target(best_target)

func _is_hostile_threat(threat: EntityManager.EntityData) -> bool:
	# Don't shoot our own faction's torpedoes
	if threat.faction_type == owner_ship._get_faction_type():
		return false
	
	# Don't shoot torpedoes we own (if owner_id is set)
	if threat.owner_id and threat.owner_id == owner_ship.entity_id:
		return false
	
	# Check if torpedo is heading roughly toward us
	var threat_to_ship = owner_ship.global_position - threat.position
	var threat_velocity = threat.velocity
	
	# If torpedo is moving away from us, ignore it
	if threat_velocity.length() > 0:
		var velocity_to_ship_dot = threat_velocity.normalized().dot(threat_to_ship.normalized())
		if velocity_to_ship_dot < -0.3:  # Moving away from us
			return false
	
	return true

func _select_best_target(threats: Array) -> EntityManager.EntityData:
	if threats.is_empty():
		return null
	
	var ship_position = owner_ship.global_position
	var best_target = null
	var best_score = -1.0
	
	for threat in threats:
		var distance = ship_position.distance_to(threat.position)
		var firing_range_pixels = firing_range_meters / WorldSettings.meters_per_pixel
		
		# Skip if out of firing range
		if distance > firing_range_pixels:
			continue
		
		# Calculate threat score (higher = more dangerous)
		var threat_score = _calculate_threat_score(threat, distance)
		
		if threat_score > best_score:
			best_score = threat_score
			best_target = threat
	
	return best_target

func _calculate_threat_score(threat: EntityManager.EntityData, distance: float) -> float:
	var score = 0.0
	
	# Closer threats are more dangerous
	var max_range = firing_range_meters / WorldSettings.meters_per_pixel
	score += (1.0 - distance / max_range) * 100.0
	
	# Faster threats are more dangerous
	var speed = threat.velocity.length()
	score += speed * 0.1
	
	# Threats heading toward us are more dangerous
	var threat_to_ship = owner_ship.global_position - threat.position
	if threat.velocity.length() > 0 and threat_to_ship.length() > 0:
		var heading_dot = threat.velocity.normalized().dot(threat_to_ship.normalized())
		score += max(0.0, heading_dot) * 50.0
	
	return score

func _is_better_target(new_target: EntityManager.EntityData, old_target: EntityManager.EntityData) -> bool:
	var ship_position = owner_ship.global_position
	var new_distance = ship_position.distance_to(new_target.position)
	var old_distance = ship_position.distance_to(old_target.position)
	
	var new_score = _calculate_threat_score(new_target, new_distance)
	var old_score = _calculate_threat_score(old_target, old_distance)
	
	# Add hysteresis to prevent target switching spam
	return new_score > old_score * 1.2

func _acquire_target(target: EntityManager.EntityData):
	if current_target != target:
		current_target = target
		target_lock_time = Time.get_ticks_msec() / 1000.0
		print("Point Defense acquired target: ", target.entity_id)

func _update_target_tracking(delta: float):
	if not current_target:
		return
	
	# Check if target is still valid
	if not current_target.is_valid() or current_target.state == EntityManager.EntityState.DESTROYED:
		_lose_target()
		return
	
	# Check if target is still in range
	var distance = owner_ship.global_position.distance_to(current_target.position)
	var max_range = firing_range_meters / WorldSettings.meters_per_pixel
	if distance > max_range:
		_lose_target()
		return
	
	# Check if target is still hostile
	if not _is_hostile_threat(current_target):
		_lose_target()
		return
	
	# Update turret rotation to track target
	_update_turret_rotation(delta)

func _lose_target():
	if current_target:
		print("Point Defense lost target: ", current_target.entity_id)
		current_target = null
		target_lock_time = 0.0

func _update_turret_rotation(delta: float):
	if not current_target:
		return
	
	# Calculate lead angle for moving target
	var target_pos = _calculate_intercept_point()
	var target_direction = (target_pos - global_position).normalized()
	var target_angle = target_direction.angle()
	
	# Rotate turret toward target
	var angle_diff = angle_difference(current_rotation, target_angle)
	var max_rotation = rotation_speed * delta
	
	if abs(angle_diff) > max_rotation:
		current_rotation += sign(angle_diff) * max_rotation
	else:
		current_rotation = target_angle
	
	# Update visual components
	if turret_sprite:
		turret_sprite.rotation = current_rotation

func _calculate_intercept_point() -> Vector2:
	if not current_target:
		return Vector2.ZERO
	
	# Simple intercept calculation
	var target_pos = current_target.position
	var target_vel = current_target.velocity
	var projectile_speed = 2000.0  # Assume instant hit for point defense
	
	# For point defense, we'll use a simple prediction
	var time_to_target = global_position.distance_to(target_pos) / projectile_speed
	return target_pos + target_vel * time_to_target

func _can_fire() -> bool:
	var current_time = Time.get_ticks_msec() / 1000.0
	
	# Check firing rate
	if current_time - last_shot_time < firing_interval:
		return false
	
	# Check reaction time
	if current_time - target_lock_time < reaction_time:
		return false
	
	# Check if turret is aimed
	var target_pos = _calculate_intercept_point()
	var target_direction = (target_pos - global_position).normalized()
	var target_angle = target_direction.angle()
	var aim_error = abs(angle_difference(current_rotation, target_angle))
	
	# Must be aimed within 5 degrees
	return aim_error < deg_to_rad(5.0)

func _fire_at_target():
	if not current_target:
		return
	
	var current_time = Time.get_ticks_msec() / 1000.0
	last_shot_time = current_time
	
	# Calculate hit chance
	var hit_roll = randf()
	if hit_roll <= accuracy:
		_hit_target()
	else:
		_miss_target()

func _hit_target():
	if not current_target:
		return
	
	print("Point Defense HIT: ", current_target.entity_id)
	
	# Destroy the target
	if current_target.node_ref and is_instance_valid(current_target.node_ref):
		# If the torpedo has a hit method, use it
		if current_target.node_ref.has_method("hit_by_point_defense"):
			current_target.node_ref.hit_by_point_defense()
		else:
			# Otherwise, queue it for destruction
			current_target.node_ref.queue_free()
	
	# Update entity state
	EntityManager.set_entity_state(current_target.entity_id, EntityManager.EntityState.DESTROYED)
	
	# Clear target
	_lose_target()
	
	# Visual/audio feedback would go here
	_create_hit_effect()

func _miss_target():
	if current_target:
		print("Point Defense MISS: ", current_target.entity_id)
	
	# Visual/audio feedback would go here
	_create_miss_effect()

func _create_hit_effect():
	# Placeholder for hit effects
	# You could spawn a small explosion particle effect here
	pass

func _create_miss_effect():
	# Placeholder for miss effects
	# You could spawn a small muzzle flash here
	pass

func _find_owner_ship() -> BaseShip:
	var parent = get_parent()
	while parent:
		if parent is BaseShip:
			return parent
		parent = parent.get_parent()
	return null

# Utility function for angle difference
func angle_difference(angle1: float, angle2: float) -> float:
	var diff = angle2 - angle1
	while diff > PI:
		diff -= 2 * PI
	while diff < -PI:
		diff += 2 * PI
	return diff

# Debug method
func get_debug_info() -> String:
	var status = "SCANNING"
	if current_target:
		status = "TRACKING: " + current_target.entity_id
	
	return "PD Cannon [%s] - Range: %.0fm - %s" % [owner_ship.name if owner_ship else "NO_OWNER", firing_range_meters, status]
