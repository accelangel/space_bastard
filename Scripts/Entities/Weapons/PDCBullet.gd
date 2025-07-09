# Scripts/Entities/Weapons/PDCBullet.gd - IMMEDIATE STATE REFACTOR
extends Area2D
class_name PDCBullet

# Identity baked into the node
@export var bullet_id: String = ""
@export var birth_time: float = 0.0
@export var faction: String = "friendly"
@export var source_pdc_id: String = ""
@export var source_ship_id: String = ""
@export var target_id: String = ""  # What the PDC was aiming at

# State management
var is_alive: bool = true
var marked_for_death: bool = false
var death_reason: String = ""

# Bullet properties
var velocity: Vector2 = Vector2.ZERO
var max_lifetime: float = 3.0  # Bullets self-destruct after 3 seconds

# References
@onready var sprite: Sprite2D = $Sprite2D

func _ready():
	# Generate unique ID if not provided
	if bullet_id == "":
		bullet_id = "bullet_%d_%d" % [Time.get_ticks_msec(), get_instance_id()]
	
	birth_time = Time.get_ticks_msec() / 1000.0
	
	# Add to groups for identification
	add_to_group("bullets")
	add_to_group("combat_entities")
	
	# Store all identity data as metadata for redundancy
	set_meta("bullet_id", bullet_id)
	set_meta("faction", faction)
	set_meta("entity_type", "pdc_bullet")
	set_meta("source_pdc_id", source_pdc_id)
	set_meta("source_ship_id", source_ship_id)
	set_meta("target_id", target_id)
	
	# Connect collision signal
	area_entered.connect(_on_area_entered)
	
	# Set rotation to match velocity
	if velocity.length() > 0:
		rotation = velocity.angle() + 3*PI/2
	
	# Notify observers
	get_tree().call_group("battle_observers", "on_entity_spawned", self, "pdc_bullet")

func _physics_process(delta):
	# Validate we're still alive
	if marked_for_death or not is_alive:
		return
	
	# Check lifetime
	var current_time = Time.get_ticks_msec() / 1000.0
	if current_time - birth_time > max_lifetime:
		mark_for_destruction("max_lifetime")
		return
	
	# Move bullet
	global_position += velocity * delta
	
	# Check if out of bounds
	var half_size = WorldSettings.map_size_pixels / 2
	if abs(global_position.x) > half_size.x or abs(global_position.y) > half_size.y:
		mark_for_destruction("out_of_bounds")
		return
	
	# Notify observers of position update (less frequently for performance)
	if Engine.get_physics_frames() % 10 == 0:  # Every 10 frames
		get_tree().call_group("battle_observers", "on_entity_moved", self, global_position)

func mark_for_destruction(reason: String):
	if marked_for_death:
		return  # Already dying
	
	marked_for_death = true
	is_alive = false
	death_reason = reason
	
	# Disable immediately
	set_physics_process(false)
	if has_node("CollisionShape2D"):
		$CollisionShape2D.disabled = true
	
	# Notify observers
	get_tree().call_group("battle_observers", "on_entity_dying", self, reason)
	
	# Safe cleanup
	queue_free()

func _on_area_entered(area: Area2D):
	if marked_for_death:
		return
	
	# Check if it's a valid collision target
	if not area.is_in_group("combat_entities"):
		return
	
	# Don't collide with same faction
	if area.get("faction") == faction:
		return
	
	# Special handling for torpedoes
	if area.is_in_group("torpedoes"):
		# Store hit information on both entities
		area.set_meta("last_hit_by", source_pdc_id)
		var torpedo_id = ""
		if "torpedo_id" in area:
			torpedo_id = area.torpedo_id
		set_meta("hit_target", torpedo_id if torpedo_id != "" else "unknown")
		
		# Mark torpedo for destruction
		if area.has_method("mark_for_destruction"):
			area.mark_for_destruction("bullet_impact")
		
		# Self destruct
		mark_for_destruction("target_impact")
		
		# Notify observers of successful intercept
		get_tree().call_group("battle_observers", "on_intercept", self, area, source_pdc_id)

func set_velocity(new_velocity: Vector2):
	velocity = new_velocity
	if velocity.length() > 0:
		rotation = velocity.angle() + 3*PI/2

func set_faction(new_faction: String):
	faction = new_faction

func set_source_pdc(pdc_id: String):
	source_pdc_id = pdc_id

func set_source_ship(ship_id: String):
	source_ship_id = ship_id

func set_target(target_entity_id: String):
	target_id = target_entity_id

# Initialize bullet with all tracking information
func initialize_bullet(bullet_faction: String, pdc_id: String, ship_id: String, target: String):
	faction = bullet_faction
	source_pdc_id = pdc_id
	source_ship_id = ship_id
	target_id = target
	
	# Update metadata
	set_meta("source_pdc_id", source_pdc_id)
	set_meta("source_ship_id", source_ship_id)
	set_meta("target_id", target_id)

# For debugging and tracking
func get_identity() -> Dictionary:
	return {
		"bullet_id": bullet_id,
		"source_pdc": source_pdc_id,
		"source_ship": source_ship_id,
		"target": target_id,
		"faction": faction,
		"age": (Time.get_ticks_msec() / 1000.0) - birth_time
	}
