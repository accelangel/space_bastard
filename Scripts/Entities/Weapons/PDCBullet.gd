# Scripts/Entities/Weapons/PDCBullet.gd - FIXED DIRECTION VERSION
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

# Debug
var debug_first_bullet: bool = true
static var bullet_count: int = 0

func _ready():
	bullet_count += 1
	var my_bullet_num = bullet_count
	
	# Register with EntityManager
	var entity_manager = get_node_or_null("/root/EntityManager")
	if entity_manager:
		entity_id = entity_manager.register_entity(self, "pdc_bullet", faction)
	
	# Connect collision signal
	area_entered.connect(_on_area_entered)
	
	# Debug first few bullets
	if my_bullet_num <= 5:
		print("BULLET #%d DEBUG:" % my_bullet_num)
		print("  Initial position: ", global_position)
		print("  Velocity (pixels/s): ", velocity)
		print("  Velocity magnitude: %.1f pixels/s" % velocity.length())
		print("  Velocity angle: %.1f°" % rad_to_deg(velocity.angle()))
		print("  Should be moving toward: ~105.5°")
		
		# Set up a one-shot timer to check position after 0.1 seconds
		var timer = Timer.new()
		timer.wait_time = 0.1
		timer.one_shot = true
		timer.timeout.connect(_on_debug_timer.bind(my_bullet_num))
		add_child(timer)
		timer.start()
	
	# Set sprite rotation to match velocity
	if velocity.length() > 0:
		# Assuming your bullet sprite points RIGHT in the art file
		rotation = velocity.angle()
		
		# If your bullet sprite points in a different direction, adjust here:
		# - Sprite points UP: rotation = velocity.angle() + PI/2
		# - Sprite points DOWN: rotation = velocity.angle() - PI/2
		# - Sprite points LEFT: rotation = velocity.angle() + PI

func _on_debug_timer(bullet_num: int):
	print("BULLET #%d after 0.1s:" % bullet_num)
	print("  New position: ", global_position)
	print("  Distance traveled: %.1f pixels" % global_position.distance_to(Vector2.ZERO))
	print("  Direction of travel: %.1f°" % rad_to_deg((global_position - Vector2.ZERO).angle()))

func _physics_process(delta):
	# Move bullet
	global_position += velocity * delta
	
	# Update EntityManager
	var entity_manager = get_node_or_null("/root/EntityManager")
	if entity_manager and entity_id:
		entity_manager.update_entity_position(entity_id, global_position)
	
	# Extra debug for first bullet's first few frames
	if bullet_count == 1 and Engine.get_physics_frames() < 5:
		print("Bullet frame %d pos: %s" % [Engine.get_physics_frames(), global_position])

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
		# Adjust rotation based on your bullet sprite orientation
		rotation = velocity.angle()

func set_faction(new_faction: String):
	faction = new_faction

func _exit_tree():
	# Unregister from EntityManager when destroyed
	var entity_manager = get_node_or_null("/root/EntityManager")
	if entity_manager and entity_id:
		entity_manager.unregister_entity(entity_id)
