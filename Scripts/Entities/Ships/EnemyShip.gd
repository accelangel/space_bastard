# Scripts/Ships/EnemyShip.gd - IMMEDIATE STATE REFACTOR
extends CharacterBody2D
class_name EnemyShip

# Ship identity - self-managed
@export var entity_id: String = ""
@export var faction: String = "hostile"
@export var ship_class: String = "Unknown"
@export var ship_name: String = "Hostile Contact"

# State management
var is_alive: bool = true
var marked_for_death: bool = false
var death_reason: String = ""

# Components
@onready var health_component: Node = $HealthComponent
@onready var movement_component: Node = $MovementComponent
@onready var weapon_system: Node2D = $WeaponSystem
@onready var sensor_system: SensorSystem = $SensorSystem
@onready var ship_visuals: Node2D = $ShipVisuals
@onready var collision_shape: CollisionShape2D = $CollisionShape2D

# Combat state
var current_target: Node2D = null
var last_target_check: float = 0.0
var target_check_interval: float = 2.0

# Movement parameters
@export var max_speed: float = 300.0
@export var acceleration: float = 100.0
@export var turn_rate: float = 2.0

# Weapon parameters
@export var engagement_range: float = 800.0
@export var fire_rate: float = 0.5
var time_since_last_shot: float = 0.0

func _ready():
	# Generate unique ID if not provided
	if entity_id == "":
		entity_id = "enemy_%d_%d" % [Time.get_ticks_msec(), get_instance_id()]
	
	# Self-identify
	add_to_group("ships")
	add_to_group("enemy_ships")
	add_to_group("combat_entities")
	
	# Store identity as metadata
	set_meta("entity_id", entity_id)
	set_meta("faction", faction)
	set_meta("entity_type", "enemy_ship")
	set_meta("ship_class", ship_class)
	
	# Connect health component
	if health_component:
		health_component.died.connect(_on_health_component_died)
		health_component.damaged.connect(_on_health_component_damaged)
	
	# Initialize components
	if movement_component:
		movement_component.max_speed = max_speed
		movement_component.acceleration = acceleration
		movement_component.turn_rate = turn_rate
	
	# Notify observers of spawn
	get_tree().call_group("battle_observers", "on_entity_spawned", self, "enemy_ship")
	
	print("Enemy ship spawned: %s (%s)" % [ship_name, entity_id])

func _physics_process(delta):
	if marked_for_death or not is_alive:
		return
	
	# Validate current target
	if not is_valid_target(current_target):
		current_target = null
	
	# Periodic target acquisition
	last_target_check += delta
	if last_target_check >= target_check_interval:
		acquire_target()
		last_target_check = 0.0
	
	# Movement AI
	if current_target and movement_component:
		var target_pos = current_target.global_position
		var distance = global_position.distance_to(target_pos)
		
		if distance > engagement_range * 0.8:
			# Move closer
			movement_component.move_to_position(target_pos)
		elif distance < engagement_range * 0.4:
			# Back away
			var away_direction = (global_position - target_pos).normalized()
			var retreat_pos = global_position + away_direction * 200
			movement_component.move_to_position(retreat_pos)
		else:
			# Orbit at optimal range
			movement_component.stop()
	
	# Weapon handling
	time_since_last_shot += delta
	if current_target and can_fire():
		fire_at_target()

func is_valid_target(target: Node2D) -> bool:
	if not target:
		return false
	if not is_instance_valid(target):
		return false
	if not target.is_inside_tree():
		return false
	if target.has_method("is_alive") and not target.is_alive:
		return false
	if target.get("marked_for_death") and target.marked_for_death:
		return false
	if target.get("faction") == faction:
		return false
	return true

func acquire_target():
	# Get all potential targets
	var potential_targets = []
	
	# Check player ships
	var player_ships = get_tree().get_nodes_in_group("player_ships")
	for ship in player_ships:
		if is_valid_target(ship):
			potential_targets.append(ship)
	
	# Find closest target
	var best_target = null
	var best_distance = INF
	
	for target in potential_targets:
		var distance = global_position.distance_to(target.global_position)
		if distance < best_distance and distance <= engagement_range:
			best_distance = distance
			best_target = target
	
	if best_target != current_target:
		current_target = best_target
		if current_target:
			var target_id = "unknown"
			if "entity_id" in current_target:
				target_id = current_target.entity_id
			print("%s: Engaging %s" % [entity_id, target_id])

func can_fire() -> bool:
	if not current_target:
		return false
	
	var distance = global_position.distance_to(current_target.global_position)
	return distance <= engagement_range and time_since_last_shot >= fire_rate

func fire_at_target():
	if not weapon_system or not current_target:
		return
	
	# Fire torpedoes if available
	for child in weapon_system.get_children():
		if child.has_method("fire_torpedo"):
			child.fire_torpedo(current_target)
			time_since_last_shot = 0.0
			break

func take_damage(amount: float, _damage_source: String = ""):
	if health_component:
		health_component.take_damage(amount)

func _on_health_component_died():
	mark_for_destruction("destroyed")

func _on_health_component_damaged(_amount: float):
	# Visual feedback for damage
	if ship_visuals:
		var tween = create_tween()
		tween.tween_property(ship_visuals, "modulate", Color.RED, 0.1)
		tween.tween_property(ship_visuals, "modulate", Color.WHITE, 0.1)

func mark_for_destruction(reason: String):
	if marked_for_death:
		return
	
	marked_for_death = true
	is_alive = false
	death_reason = reason
	
	# Disable physics
	set_physics_process(false)
	if collision_shape:
		collision_shape.disabled = true
	
	# Notify observers
	get_tree().call_group("battle_observers", "on_entity_dying", self, reason)
	
	# Death animation
	if ship_visuals:
		var tween = create_tween()
		tween.tween_property(ship_visuals, "scale", Vector2.ZERO, 0.5)
		tween.tween_property(ship_visuals, "modulate:a", 0.0, 0.5)
		tween.tween_callback(queue_free)
	else:
		queue_free()

# Interface methods for other systems
func get_velocity_mps() -> Vector2:
	if movement_component:
		return movement_component.get_velocity_mps()
	return velocity * WorldSettings.meters_per_pixel

func get_faction() -> String:
	return faction

func get_entity_id() -> String:
	return entity_id
