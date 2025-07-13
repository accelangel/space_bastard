# Scripts/Entities/Ships/EnemyShip.gd - FIXED WITH MOVEMENT CONTROL
extends Area2D
class_name EnemyShip

# Ship properties
@export var acceleration_gs: float = 1.5
@export var rotation_speed: float = 2.0
@export var faction: String = "hostile"

# Movement
var acceleration_mps2: float
var velocity_mps: Vector2 = Vector2.ZERO
var movement_direction: Vector2 = Vector2.ZERO

# NEW: Movement control flag
var movement_enabled: bool = false

# Identity
var entity_id: String = ""
var ship_name: String = "Hostile Contact"
var is_alive: bool = true
var marked_for_death: bool = false

# Child nodes
@onready var sensor_system: SensorSystem = $SensorSystem
@onready var fire_control_manager = $FireControlManager
var pdc_systems: Array = []

# Test movement
var test_acceleration: bool = true
var test_direction: Vector2 = Vector2(1, -1).normalized()
var test_gs: float = 0.02

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
	
	# Notify observers of spawn
	get_tree().call_group("battle_observers", "on_entity_spawned", self, "enemy_ship")
	
	# NEW: Don't start moving until mode selected
	if debug_enabled:
		print("EnemyShip spawned - waiting for mode selection")
	
	print("Enemy ship spawned: %s" % entity_id)

func _physics_process(delta):
	if marked_for_death or not is_alive:
		return
	
	# NEW: Only move if movement enabled
	if movement_enabled:
		# Update movement
		var acceleration_vector = movement_direction * acceleration_mps2
		velocity_mps += acceleration_vector * delta
		var velocity_pixels_per_second = velocity_mps / WorldSettings.meters_per_pixel
		global_position += velocity_pixels_per_second * delta
	
	# Notify sensor systems of our position for immediate state
	get_tree().call_group("sensor_systems", "report_entity_position", self, global_position, "enemy_ship", faction)

# NEW: Enable movement when mode selected
func enable_movement():
	movement_enabled = true
	if test_acceleration:
		set_acceleration(test_gs)
		set_movement_direction(test_direction)
		if debug_enabled:
			print("EnemyShip movement enabled at %.3fG" % test_gs)

func set_movement_direction(new_direction: Vector2):
	movement_direction = new_direction.normalized()

func set_acceleration(gs: float):
	acceleration_gs = gs
	acceleration_mps2 = acceleration_gs * 9.81

func get_velocity_mps() -> Vector2:
	return velocity_mps

func toggle_test_acceleration():
	test_acceleration = !test_acceleration
	if test_acceleration:
		set_movement_direction(test_direction)
	else:
		set_movement_direction(Vector2.ZERO)

# NEW: Reset function for PID tuning
func reset_for_pid_cycle():
	global_position = Vector2(55000, -28000)
	rotation = -2.35619  # -135 degrees
	velocity_mps = Vector2.ZERO
	movement_direction = test_direction
	if movement_enabled and test_acceleration:
		set_acceleration(test_gs)

func mark_for_destruction(reason: String):
	if marked_for_death:
		return
	
	marked_for_death = true
	is_alive = false
	
	# Disable physics
	set_physics_process(false)
	var collision = get_node_or_null("CollisionShape2D")
	if collision:
		collision.disabled = true
	
	# Notify observers
	get_tree().call_group("battle_observers", "on_entity_dying", self, reason)
	
	# Simple destruction
	queue_free()

func get_faction() -> String:
	return faction

func get_entity_id() -> String:
	return entity_id
	
