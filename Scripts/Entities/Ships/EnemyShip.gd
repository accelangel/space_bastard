# Scripts/Entities/Ships/EnemyShip.gd - WITH FLOATING ORIGIN SUPPORT
extends Area2D
class_name EnemyShip

# Ship properties
@export var acceleration_gs: float = 1.0
@export var rotation_speed: float = 2.0
@export var faction: String = "hostile"

# Movement
var acceleration_mps2: float
var velocity_mps: Vector2 = Vector2.ZERO
var movement_direction: Vector2 = Vector2(0, 1)  # Default movement direction

# TRUE POSITION TRACKING (for floating origin)
var true_position: Vector2 = Vector2.ZERO

# Identity
var entity_id: String = ""
var ship_name: String = "Hostile Contact"
var is_alive: bool = true
var marked_for_death: bool = false

# Child nodes
@onready var sensor_system: SensorSystem = $SensorSystem
@onready var fire_control_manager = $FireControlManager
var pdc_systems: Array = []

# DEBUG CONTROL
@export var debug_enabled: bool = false

func _ready():
	acceleration_mps2 = acceleration_gs * 9.81
	
	# Generate unique ID
	entity_id = "enemy_%d_%d" % [Time.get_ticks_msec(), get_instance_id()]
	
	# Find all PDC systems
	for child in get_children():
		if child.has_method("get_capabilities"):
			pdc_systems.append(child)
	
	# Self-identify
	add_to_group("ships")
	add_to_group("enemy_ships")
	add_to_group("combat_entities")
	
	# Store identity as metadata
	set_meta("entity_id", entity_id)
	set_meta("faction", faction)
	set_meta("entity_type", "enemy_ship")
	
	# Connect to floating origin if it exists
	if FloatingOrigin.instance:
		FloatingOrigin.instance.origin_shifted.connect(_on_origin_shifted)
	
	# Initialize true position
	true_position = FloatingOrigin.visual_to_true(global_position) if FloatingOrigin.instance else global_position
	
	# ALWAYS enable movement immediately
	enable_movement()
	
	print("Enemy ship spawned: %s" % entity_id)

func _on_origin_shifted(shift_amount: Vector2):
	"""Handle floating origin shifts - visual position already shifted by FloatingOrigin"""
	# Update our true position to compensate for the visual shift
	true_position -= shift_amount
	if debug_enabled:
		print("[EnemyShip] Origin shifted, true pos: %s, visual pos: %s" % [true_position, global_position])

func _physics_process(delta):
	if marked_for_death or not is_alive:
		return
	
	# Update movement in true space
	var acceleration_vector = movement_direction * acceleration_mps2
	velocity_mps += acceleration_vector * delta
	
	# Update true position
	var velocity_pixels_per_second = velocity_mps / WorldSettings.meters_per_pixel
	true_position += velocity_pixels_per_second * delta
	
	# Convert true position to visual position for rendering
	if FloatingOrigin.instance:
		global_position = FloatingOrigin.true_to_visual(true_position)
	else:
		global_position = true_position

func enable_movement():
	print("[EnemyShip] Movement ENABLED")
	set_movement_direction(movement_direction)
	if debug_enabled:
		print("EnemyShip movement enabled at %.3fG" % acceleration_gs)

func set_movement_direction(new_direction: Vector2):
	movement_direction = new_direction.normalized()

func set_acceleration(gs: float):
	acceleration_gs = gs
	acceleration_mps2 = acceleration_gs * 9.81

func get_velocity_mps() -> Vector2:
	return velocity_mps

func mark_for_destruction(_reason: String):
	if marked_for_death:
		return
	
	marked_for_death = true
	is_alive = false
	
	# Disable physics
	set_physics_process(false)
	var collision = get_node_or_null("CollisionShape2D")
	if collision:
		collision.disabled = true
	
	print("Enemy ship destroyed!")
	
	# Simple destruction
	queue_free()

func get_faction() -> String:
	return faction

func get_entity_id() -> String:
	return entity_id

func get_true_position() -> Vector2:
	"""Get true world position for accurate distance calculations"""
	return true_position

func get_true_distance_to(other_pos: Vector2) -> float:
	"""Calculate true distance to another position"""
	# If other_pos is visual, it's already in the same space as our visual position
	return global_position.distance_to(other_pos)
