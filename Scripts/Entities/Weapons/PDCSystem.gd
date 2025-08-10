# Scripts/Entities/Weapons/PDCSystem.gd - SIMPLIFIED VERSION
extends Node2D
class_name PDCSystem

# Simple global toggle - edit this to enable/disable all PDCs
@export var pdcs_globally_enabled: bool = true

# Identity
@export var pdc_id: String = ""
var mount_position: Vector2

# PDC Hardware Configuration
@export var turret_rotation_speed: float = 360.0  # degrees/second
@export var max_rotation_speed_multiplier: float = 2.0
@export var bullet_velocity_mps: float = 1100.0
@export var rounds_per_second: float = 18.0
@export var max_tracking_error: float = 5.0  # degrees

# Immediate state - no stored IDs
var current_target: Node2D = null
var is_firing: bool = false
var fire_timer: float = 0.0
var current_rotation: float = 0.0
var target_rotation: float = 0.0
var emergency_slew: bool = false

# State management
var is_alive: bool = true
var marked_for_death: bool = false

# References
var parent_ship: Node2D
var fire_control_manager: Node
var rotation_pivot: Marker2D
var sprite: Sprite2D
var muzzle_point: Marker2D

# Preload bullet scene
var bullet_scene: PackedScene = preload("res://Scenes/PDCBullet.tscn")

func _ready():
	# Generate ID if not provided
	if pdc_id == "":
		pdc_id = "pdc_%d_%d" % [Time.get_ticks_msec(), get_instance_id()]
	
	parent_ship = get_parent()
	setup_sprite_references()
	mount_position = position
	
	# Add to groups
	add_to_group("pdcs")
	add_to_group("combat_entities")
	
	# Store identity as metadata
	set_meta("pdc_id", pdc_id)
	set_meta("entity_type", "pdc")
	
	set_idle_rotation()
	
	print("PDC initialized: %s at position %s" % [pdc_id, mount_position])

func setup_sprite_references():
	rotation_pivot = get_node_or_null("RotationPivot")
	if rotation_pivot:
		sprite = rotation_pivot.get_node_or_null("Sprite2D")
		if sprite:
			muzzle_point = sprite.get_node_or_null("MuzzlePoint")
	else:
		sprite = get_node_or_null("Sprite2D")
		if sprite:
			muzzle_point = sprite.get_node_or_null("MuzzlePoint")

func set_idle_rotation():
	if not parent_ship:
		current_rotation = 0.0
		target_rotation = 0.0
		return
	
	# Idle position faces ship forward (0 rotation)
	current_rotation = 0.0
	target_rotation = 0.0
	
	update_sprite_rotation()

# Validation helper
func is_valid_target(target: Node2D) -> bool:
	if not target:
		return false
	# Check if object is freed FIRST before ANY method calls
	if not is_instance_valid(target):
		return false
	# Only after instance validation can we safely call methods
	if not target.is_inside_tree():
		return false
	# Now safe to check properties
	if not target.has_method("mark_for_destruction"):
		return false
	if target.get("marked_for_death"):
		return false
	return true

func _physics_process(delta):
	# SIMPLE: Check global enable flag first
	if not pdcs_globally_enabled:
		if is_firing:
			stop_firing()
		if current_target:
			current_target = null
		return
		
	if marked_for_death or not is_alive:
		return
	
	# Check instance validity BEFORE passing to any function
	if current_target != null:
		if not is_instance_valid(current_target):
			# Target has been freed, clear it properly
			set_target(null)
			return
		# Now safe to check other validity conditions
		if not is_valid_target(current_target):
			# Target has become invalid for other reasons
			set_target(null)
			return
	
	# Only process if we have a valid target
	if current_target:
		update_target_angle()
		update_turret_rotation(delta)
		handle_firing(delta)

func update_turret_rotation(delta):
	if not rotation_pivot and not sprite:
		return
	
	var angle_diff = angle_difference(current_rotation, target_rotation)
	var rotation_speed = deg_to_rad(turret_rotation_speed)
	
	if emergency_slew:
		rotation_speed *= max_rotation_speed_multiplier
	
	var rotation_step = rotation_speed * delta
	
	if abs(angle_diff) > rotation_step:
		current_rotation += sign(angle_diff) * rotation_step
	else:
		current_rotation = target_rotation
	
	update_sprite_rotation()

func update_sprite_rotation():
	if not rotation_pivot and not sprite:
		return
	
	var sprite_rotation = calculate_sprite_rotation()
	
	if rotation_pivot:
		rotation_pivot.rotation = sprite_rotation
	elif sprite:
		sprite.rotation = sprite_rotation

func calculate_sprite_rotation() -> float:
	# User's fix for idle direction: current_rotation + PI
	# When firing, add PI/2 to correct 90-degree counter-clockwise offset
	if is_firing and current_target:
		return current_rotation + PI + PI/2
	else:
		return current_rotation + PI

func handle_firing(delta):
	# Extra safety check
	if not current_target or not is_instance_valid(current_target):
		stop_firing()
		return
		
	if not is_valid_target(current_target):
		stop_firing()
		return
	
	# Check if aimed and start firing if not already
	if is_aimed() and not is_firing:
		start_firing()
	elif not is_aimed() and is_firing:
		stop_firing()
	
	# Fire bullets if we're firing and aimed
	if is_firing and is_aimed():
		fire_timer += delta
		var fire_interval = 1.0 / rounds_per_second
		
		if fire_timer >= fire_interval:
			fire_bullet()
			fire_timer = 0.0
	else:
		fire_timer = 0.0

func set_target(new_target: Node2D):
	# Extra validation before setting target
	if new_target != null and not is_valid_target(new_target):
		current_target = null
		stop_firing()
		return
	
	# Direct node reference, no IDs
	if is_valid_target(new_target):
		current_target = new_target
		update_target_angle()
	else:
		current_target = null
		stop_firing()

func update_target_angle():
	# Extra safety check
	if not current_target or not is_instance_valid(current_target):
		return
		
	if not is_valid_target(current_target):
		return
	
	# Calculate angle to target from PDC position
	var to_target = current_target.global_position - get_muzzle_world_position()
	var world_angle = to_target.angle()
	
	# Convert world angle to ship-relative angle
	# The PDC's 0 rotation should point along ship's forward direction
	target_rotation = world_angle - parent_ship.rotation
	
	# Normalize the angle
	while target_rotation > PI:
		target_rotation -= TAU
	while target_rotation < -PI:
		target_rotation += TAU
	
	# Check if we need emergency slew
	var angle_diff = abs(angle_difference(current_rotation, target_rotation))
	emergency_slew = angle_diff > deg_to_rad(90)

func start_firing():
	# Extra safety check
	if not current_target or not is_instance_valid(current_target):
		return
		
	if not is_valid_target(current_target):
		return
	
	if not is_firing:
		is_firing = true
		var error = rad_to_deg(get_tracking_error())
		var target_id = current_target.get("torpedo_id") if current_target and is_instance_valid(current_target) else "unknown"
		print("PDC %s: Weapons free on %s (AIMED, error: %.1f°)" % [pdc_id, target_id, error])

func stop_firing():
	if is_firing:
		is_firing = false
		fire_timer = 0.0

func is_aimed() -> bool:
	var angle_diff = abs(angle_difference(current_rotation, target_rotation))
	return angle_diff < deg_to_rad(max_tracking_error)

func get_tracking_error() -> float:
	return abs(angle_difference(current_rotation, target_rotation))

func fire_bullet():
	# Extra safety check
	if not bullet_scene or not current_target or not is_instance_valid(current_target):
		return
		
	if not is_valid_target(current_target):
		return
	
	var bullet = bullet_scene.instantiate()
	
	# Set bullet properties BEFORE adding to scene tree
	bullet.global_position = get_muzzle_world_position()
	
	# Initialize bullet with full tracking info BEFORE adding to scene
	var ship_id = parent_ship.get("entity_id") if parent_ship else ""
	var torpedo_target_id = current_target.get("torpedo_id") if current_target and is_instance_valid(current_target) else ""
	bullet.initialize_bullet(parent_ship.get("faction"), pdc_id, ship_id, torpedo_target_id)
	
	# Now add to scene (this will call _ready() with proper data)
	get_tree().root.add_child(bullet)
	
	# Use PDC rotation to determine firing direction
	var world_angle = current_rotation + parent_ship.rotation
	var fire_direction = Vector2.from_angle(world_angle)
	
	# Include ship velocity for proper physics
	var ship_velocity = get_ship_velocity()
	var bullet_velocity = fire_direction * bullet_velocity_mps + ship_velocity
	var bullet_velocity_pixels = bullet_velocity / WorldSettings.meters_per_pixel
	
	bullet.set_velocity(bullet_velocity_pixels)

func get_muzzle_world_position() -> Vector2:
	if muzzle_point:
		return muzzle_point.global_position
	elif rotation_pivot:
		return rotation_pivot.global_position
	return global_position

func get_ship_velocity() -> Vector2:
	if parent_ship and parent_ship.has_method("get_velocity_mps"):
		return parent_ship.get_velocity_mps()
	return Vector2.ZERO

func angle_difference(from: float, to: float) -> float:
	var diff = fmod(to - from, TAU)
	if diff > PI:
		diff -= TAU
	elif diff < -PI:
		diff += TAU
	return diff

func emergency_stop():
	current_target = null
	stop_firing()
	emergency_slew = false
	set_idle_rotation()

# Status reporting
func get_status() -> Dictionary:
	var tracking_error = get_tracking_error()
	var status_str = "FIRING" if is_firing else "TRACKING" if current_target else "IDLE"
	
	return {
		"pdc_id": pdc_id,
		"status": status_str,
		"current_rotation": current_rotation,
		"target_rotation": target_rotation,
		"tracking_error": tracking_error,
		"is_aimed": is_aimed(),
		"has_target": current_target != null,
		"mount_position": mount_position
	}

func get_capabilities() -> Dictionary:
	return {
		"rotation_speed": turret_rotation_speed,
		"max_rotation_speed": turret_rotation_speed * max_rotation_speed_multiplier,
		"bullet_velocity": bullet_velocity_mps,
		"fire_rate": rounds_per_second,
		"max_tracking_error": max_tracking_error
	}

func set_fire_control_manager(manager: Node):
	fire_control_manager = manager
