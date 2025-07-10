# Scripts/Ships/PlayerShip.gd - IMMEDIATE STATE REFACTOR
extends Area2D
class_name PlayerShip

# Ship identity - self-managed
@export var entity_id: String = ""
@export var faction: String = "friendly"
@export var ship_class: String = "Frigate"
@export var ship_name: String = "Player Ship"

# State management
var is_alive: bool = true
var marked_for_death: bool = false
var death_reason: String = ""

# Components
@onready var movement_component: Node = $MovementComponent
@onready var fire_control_manager: FireControlManager = $FireControlManager
@onready var sensor_system: SensorSystem = $SensorSystem
@onready var torpedo_launcher: Node2D = $TorpedoLauncher
@onready var health_component: Node = $HealthComponent

# Movement state
var mouse_world_position: Vector2 = Vector2.ZERO
var is_moving_to_position: bool = false
var target_position: Vector2 = Vector2.ZERO

# Combat state
var selected_target: Node2D = null

func _ready():
	# Generate unique ID if not provided
	if entity_id == "":
		entity_id = "player_%d_%d" % [Time.get_ticks_msec(), get_instance_id()]
	
	# Self-identify
	add_to_group("ships")
	add_to_group("player_ships")
	add_to_group("combat_entities")
	
	# Store identity as metadata
	set_meta("entity_id", entity_id)
	set_meta("faction", faction)
	set_meta("entity_type", "player_ship")
	set_meta("ship_class", ship_class)
	
	# Connect health component
	if health_component:
		health_component.died.connect(_on_health_component_died)
		health_component.damaged.connect(_on_health_component_damaged)
	
	# Initialize UI connections
	setup_ui_connections()
	
	# Notify observers of spawn
	get_tree().call_group("battle_observers", "on_entity_spawned", self, "player_ship")
	
	print("Player ship spawned: %s (%s)" % [ship_name, entity_id])

func _physics_process(_delta):
	if marked_for_death or not is_alive:
		return
	
	# Update mouse position
	mouse_world_position = get_global_mouse_position()
	
	# Handle movement
	if is_moving_to_position and movement_component:
		var distance_to_target = global_position.distance_to(target_position)
		if distance_to_target < 50:
			is_moving_to_position = false
			movement_component.stop()
		else:
			movement_component.move_to_position(target_position)
	
	# Validate selected target
	if not is_valid_target(selected_target):
		selected_target = null
		update_ui_target_info()

func _input(event):
	if marked_for_death or not is_alive:
		return
	
	# Right-click movement
	if event.is_action_pressed("right_click"):
		target_position = mouse_world_position
		is_moving_to_position = true
	
	# Stop movement
	if event.is_action_pressed("stop_ship"):
		is_moving_to_position = false
		if movement_component:
			movement_component.stop()
	
	# Target selection
	if event.is_action_pressed("left_click"):
		select_target_at_mouse()
	
	# Fire torpedoes
	if event.is_action_pressed("fire_torpedoes"):
		fire_torpedoes()
	
	# Toggle PDCs
	if event.is_action_pressed("toggle_pdcs"):
		toggle_pdc_state()

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
	return true

func select_target_at_mouse():
	var space_state = get_world_2d().direct_space_state
	var params = PhysicsPointQueryParameters2D.new()
	params.position = mouse_world_position
	params.collision_mask = 0xFFFFFFFF
	params.collide_with_areas = true
	params.collide_with_bodies = true
	
	var results = space_state.intersect_point(params, 10)
	
	# Find the best target
	for result in results:
		var collider = result.collider
		if collider != self and collider.is_in_group("combat_entities"):
			if collider.get("faction") != faction:
				selected_target = collider
				update_ui_target_info()
				print("Target selected: %s" % collider.get("entity_id", "unknown"))
				return

func fire_torpedoes():
	if not torpedo_launcher or not selected_target:
		return
	
	if torpedo_launcher.has_method("fire_torpedo"):
		torpedo_launcher.fire_torpedo(selected_target)

func toggle_pdc_state():
	if not fire_control_manager:
		return
	
	# PDCs now auto-engage, this could toggle engagement rules
	print("PDC systems active")

func take_damage(amount: float, _damage_source: String = ""):
	if health_component:
		health_component.take_damage(amount)

func _on_health_component_died():
	mark_for_destruction("destroyed")

func _on_health_component_damaged(_amount: float):
	# Update UI and visual feedback
	update_ui_health()
	
	# Flash red
	var sprite = get_node_or_null("ShipVisuals")
	if sprite:
		var tween = create_tween()
		tween.tween_property(sprite, "modulate", Color.RED, 0.1)
		tween.tween_property(sprite, "modulate", Color.WHITE, 0.1)

func mark_for_destruction(reason: String):
	if marked_for_death:
		return
	
	marked_for_death = true
	is_alive = false
	death_reason = reason
	
	# Disable physics
	set_physics_process(false)
	set_process_input(false)
	
	var collision = get_node_or_null("CollisionShape2D")
	if collision:
		collision.disabled = true
	
	# Notify observers
	get_tree().call_group("battle_observers", "on_entity_dying", self, reason)
	
	# Update UI
	update_ui_death()
	
	# Don't immediately destroy player ship - might want death screen
	print("Player ship destroyed!")

# UI Integration
func setup_ui_connections():
	# Connect to HUD if it exists
	var hud = get_tree().get_first_node_in_group("hud")
	if hud:
		print("Connected to HUD")

func update_ui_target_info():
	var hud = get_tree().get_first_node_in_group("hud")
	if not hud:
		return
	
	if selected_target and is_valid_target(selected_target):
		var target_name = "Unknown"
		var target_class = "Unknown"
		var target_faction = "Unknown"
		
		if "ship_name" in selected_target:
			target_name = selected_target.ship_name
		if "ship_class" in selected_target:
			target_class = selected_target.ship_class
		if "faction" in selected_target:
			target_faction = selected_target.faction
		
		var target_info = {
			"name": target_name,
			"class": target_class,
			"faction": target_faction,
			"distance": global_position.distance_to(selected_target.global_position) * WorldSettings.meters_per_pixel
		}
		
		if hud.has_method("update_target_info"):
			hud.update_target_info(target_info)
	else:
		if hud.has_method("clear_target_info"):
			hud.clear_target_info()

func update_ui_health():
	var hud = get_tree().get_first_node_in_group("hud")
	if hud and health_component and hud.has_method("update_health"):
		hud.update_health(health_component.current_health, health_component.max_health)

func update_ui_death():
	var hud = get_tree().get_first_node_in_group("hud")
	if hud and hud.has_method("show_death_screen"):
		hud.show_death_screen()

# Interface methods
func get_velocity_mps() -> Vector2:
	if movement_component:
		return movement_component.get_velocity_mps()
	return Vector2.ZERO  # Area2D doesn't have built-in velocity

func get_faction() -> String:
	return faction

func get_entity_id() -> String:
	return entity_id
