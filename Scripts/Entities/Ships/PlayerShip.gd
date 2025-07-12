# Scripts/Entities/Ships/PlayerShip.gd - WITH FIXED MULTI-ANGLE TORPEDO SUPPORT
extends Area2D
class_name PlayerShip

# Ship properties
@export var acceleration_gs: float = 0.05
@export var rotation_speed: float = 2.0
@export var faction: String = "friendly"

# Torpedo configuration
@export var use_multi_angle_torpedoes: bool = true

# Movement
var acceleration_mps2: float
var velocity_mps: Vector2 = Vector2.ZERO
var movement_direction: Vector2 = Vector2.ZERO

# Identity
var entity_id: String = ""
var ship_name: String = "Player Ship"
var is_alive: bool = true
var marked_for_death: bool = false

# Child nodes
@onready var sensor_system: SensorSystem = $SensorSystem
@onready var torpedo_launcher: Node2D = $TorpedoLauncher
@onready var fire_control_manager = $FireControlManager

# Test movement
var test_acceleration: bool = true
var test_direction: Vector2 = Vector2(1, -1).normalized()
var test_gs: float = 1.0

# Auto battle system
var auto_battle_started: bool = false
var battle_start_delay: float = 2.0  # Delay before firing torpedoes
var battle_timer: float = 0.0

# DEBUG CONTROL
@export var debug_enabled: bool = false

func _ready():
	acceleration_mps2 = acceleration_gs * 9.81
	
	# Generate unique ID
	entity_id = "player_%d_%d" % [Time.get_ticks_msec(), get_instance_id()]
	
	# Configure torpedo launcher for multi-angle torpedoes
	if torpedo_launcher and use_multi_angle_torpedoes:
		if torpedo_launcher.has_method("set_torpedo_type"):
			var multi_angle_type = TorpedoType.new()
			multi_angle_type.torpedo_name = "Multi-Angle Torpedo"
			multi_angle_type.flight_pattern = TorpedoType.FlightPattern.MULTI_ANGLE
			multi_angle_type.approach_angle_offset = 30.0  # Reduced from 45
			multi_angle_type.arc_strength = 0.3  # Much lower default
			multi_angle_type.maintain_offset_distance = 500.0
			multi_angle_type.navigation_constant = 4.0  # Slightly higher for better tracking
			torpedo_launcher.set_torpedo_type(multi_angle_type)
			print("Player ship configured for Multi-Angle torpedoes")
	
	# Self-identify
	add_to_group("ships")
	add_to_group("player_ships")
	add_to_group("combat_entities")
	
	# Store identity as metadata
	set_meta("entity_id", entity_id)
	set_meta("faction", faction)
	set_meta("entity_type", "player_ship")
	
	# Notify observers of spawn
	get_tree().call_group("battle_observers", "on_entity_spawned", self, "player_ship")
	
	# Set up test acceleration
	if test_acceleration:
		set_acceleration(test_gs)
		set_movement_direction(test_direction)
		if debug_enabled:
			print("PlayerShip starting test acceleration at %.1fG" % test_gs)
	
	print("Player ship spawned: %s" % entity_id)

func _physics_process(delta):
	if marked_for_death or not is_alive:
		return
		
	# Update movement
	var acceleration_vector = movement_direction * acceleration_mps2
	velocity_mps += acceleration_vector * delta
	var velocity_pixels_per_second = velocity_mps / WorldSettings.meters_per_pixel
	global_position += velocity_pixels_per_second * delta
	
	# Auto battle system - start firing torpedoes after delay
	if not auto_battle_started:
		battle_timer += delta
		if battle_timer >= battle_start_delay:
			start_auto_battle()
	
	# Notify sensor systems of our position for immediate state
	get_tree().call_group("sensor_systems", "report_entity_position", self, global_position, "player_ship", faction)

func start_auto_battle():
	"""Automatically fire torpedoes to start the battle"""
	if auto_battle_started:
		return
		
	auto_battle_started = true
	print("Auto-starting battle - firing %s torpedoes" % 
		("Multi-Angle" if use_multi_angle_torpedoes else "Basic"))
	fire_torpedoes_at_enemy()

func _input(event):
	if marked_for_death or not is_alive:
		return
	
	# Manual fire torpedoes on spacebar (still available for testing)
	if event.is_action_pressed("ui_accept"):
		print("Manual torpedo launch triggered")
		fire_torpedoes_at_enemy()
	
	# Toggle torpedo type on T key
	if event.is_action_pressed("ui_text_completion_query"):  # T key
		toggle_torpedo_type()

func toggle_torpedo_type():
	use_multi_angle_torpedoes = !use_multi_angle_torpedoes
	
	if torpedo_launcher and torpedo_launcher.has_method("set_torpedo_type"):
		if use_multi_angle_torpedoes:
			var multi_angle_type = TorpedoType.new()
			multi_angle_type.torpedo_name = "Multi-Angle Torpedo"
			multi_angle_type.flight_pattern = TorpedoType.FlightPattern.MULTI_ANGLE
			multi_angle_type.approach_angle_offset = 30.0  # Reduced from 45
			multi_angle_type.arc_strength = 0.3  # Much lower default
			multi_angle_type.maintain_offset_distance = 500.0
			multi_angle_type.navigation_constant = 4.0  # Slightly higher for better tracking
			torpedo_launcher.set_torpedo_type(multi_angle_type)
		else:
			var basic_type = TorpedoType.new()
			basic_type.torpedo_name = "Basic Torpedo"
			basic_type.flight_pattern = TorpedoType.FlightPattern.BASIC
			torpedo_launcher.set_torpedo_type(basic_type)
		
		print("Switched to %s torpedoes" % ("Multi-Angle" if use_multi_angle_torpedoes else "Basic"))

func fire_torpedoes_at_enemy():
	if not torpedo_launcher:
		print("No torpedo launcher!")
		return
		
	# Find closest enemy ship
	var enemy_ships = get_tree().get_nodes_in_group("enemy_ships")
	var closest_enemy = null
	var closest_distance = INF
	
	for ship in enemy_ships:
		if ship.get("is_alive") and ship.is_alive:
			var distance = global_position.distance_to(ship.global_position)
			if distance < closest_distance:
				closest_distance = distance
				closest_enemy = ship
	
	if closest_enemy:
		print("Player firing torpedoes at enemy ship")
		torpedo_launcher.fire_torpedo(closest_enemy)
	else:
		print("No enemy ships found to target")

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

func mark_for_destruction(reason: String):
	if marked_for_death:
		return
	
	marked_for_death = true
	is_alive = false
	
	# Disable physics
	set_physics_process(false)
	set_process_input(false)
	
	var collision = get_node_or_null("CollisionShape2D")
	if collision:
		collision.disabled = true
	
	# Notify observers
	get_tree().call_group("battle_observers", "on_entity_dying", self, reason)
	
	print("Player ship destroyed!")

func get_faction() -> String:
	return faction

func get_entity_id() -> String:
	return entity_id
