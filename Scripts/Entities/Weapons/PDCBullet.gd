# Scripts/Entities/Weapons/PDCBullet.gd - FIXED BULLET ORIENTATION
extends Area2D
class_name PDCBullet

# Signals
signal hit_target

# Bullet properties
var velocity: Vector2 = Vector2.ZERO
var faction: String = "friendly"
var entity_id: String

# References
@onready var sprite: Sprite2D = $Sprite2D

func _ready():
	# Register with EntityManager
	var entity_manager = get_node_or_null("/root/EntityManager")
	if entity_manager:
		entity_id = entity_manager.register_entity(self, "pdc_bullet", faction)
	
	# Connect collision signal
	area_entered.connect(_on_area_entered)
	
	# Set rotation to match velocity - FIXED
	if velocity.length() > 0:
		# FIXED: Simple angle calculation without random offsets
		rotation = velocity.angle()

func _physics_process(delta):
	# Move bullet
	global_position += velocity * delta
	
	# Update EntityManager
	var entity_manager = get_node_or_null("/root/EntityManager")
	if entity_manager and entity_id:
		entity_manager.update_entity_position(entity_id, global_position)

func _on_area_entered(area: Area2D):
	# Check if we hit something hostile
	if is_hostile_to(area):
		# Emit signal before destroying
		hit_target.emit()
		
		# Both bullet and target die instantly
		area.queue_free()
		queue_free()

func is_hostile_to(other: Node) -> bool:
	if not "faction" in other:
		return false
	
	# Simple faction check
	if faction == "friendly":
		return other.faction == "hostile"
	elif faction == "hostile":
		return other.faction == "friendly"
	
	return false

func set_velocity(new_velocity: Vector2):
	velocity = new_velocity
	if velocity.length() > 0:
		# FIXED: Simple angle calculation
		rotation = velocity.angle()

func set_faction(new_faction: String):
	faction = new_faction

func _exit_tree():
	# Unregister from EntityManager when destroyed
	var entity_manager = get_node_or_null("/root/EntityManager")
	if entity_manager and entity_id:
		entity_manager.unregister_entity(entity_id)
