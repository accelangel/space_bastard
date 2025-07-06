# Universal Rotation Framework for Space Combat Game
# This framework ensures consistent orientation handling across all game objects

"""
CORE PRINCIPLES:

1. WORLD SPACE RULES:
   - 0 degrees = RIGHT (+X axis) in Godot world space
   - Positive rotation = counterclockwise
   - All calculations done in world space first, then converted

2. SHIP SPACE RULES:
   - Ship "forward" is ALWAYS Vector2.UP (toward -Y) regardless of art orientation
   - All child objects use ship-relative coordinates
   - Ship rotation affects all children consistently

3. ART ORIENTATION STANDARDS:
   - All ship sprites drawn pointing UP in the art file
   - All weapon sprites drawn pointing UP in the art file
   - Rotation pivots explicitly defined with Marker2D nodes

4. CONVERSION FUNCTIONS:
   - Always use these functions for angle conversions
   - Never do manual angle math outside these functions
"""

class_name RotationFramework
extends RefCounted

# CORE CONSTANTS - These define our coordinate system
const WORLD_RIGHT: Vector2 = Vector2.RIGHT        # 0 degrees in world space
const WORLD_UP: Vector2 = Vector2.UP              # -90 degrees in world space  
const SHIP_FORWARD: Vector2 = Vector2.UP          # Ship's forward direction in local space
const SPRITE_UP_OFFSET: float = PI/2              # Offset for sprites drawn pointing up

# ANGLE CONVERSION FUNCTIONS

static func world_angle_to_direction(angle: float) -> Vector2:
	"""Convert world angle to direction vector"""
	return Vector2.from_angle(angle)

static func direction_to_world_angle(direction: Vector2) -> float:
	"""Convert direction vector to world angle"""
	return direction.angle()

static func ship_relative_to_world_angle(ship_angle: float, relative_angle: float) -> float:
	"""Convert ship-relative angle to world angle"""
	return ship_angle + relative_angle

static func world_to_ship_relative_angle(ship_angle: float, world_angle: float) -> float:
	"""Convert world angle to ship-relative angle"""
	var relative = world_angle - ship_angle
	return normalize_angle(relative)

static func normalize_angle(angle: float) -> float:
	"""Normalize angle to [-PI, PI] range"""
	while angle > PI:
		angle -= TAU
	while angle < -PI:
		angle += TAU
	return angle

static func angle_difference(from: float, to: float) -> float:
	"""Calculate shortest angular difference between two angles"""
	var diff = to - from
	return normalize_angle(diff)

# SPRITE ORIENTATION HELPERS

static func get_sprite_rotation_for_world_angle(world_angle: float, ship_rotation: float, sprite_art_offset: float = SPRITE_UP_OFFSET) -> float:
	"""Calculate sprite rotation needed to point sprite in world direction"""
	# Convert world angle to ship-relative
	var ship_relative = world_to_ship_relative_angle(ship_rotation, world_angle)
	# Apply sprite art offset (sprites drawn pointing up need -90° offset)
	return ship_relative - sprite_art_offset

static func get_world_angle_from_sprite_rotation(sprite_rotation: float, ship_rotation: float, sprite_art_offset: float = SPRITE_UP_OFFSET) -> float:
	"""Calculate world angle that sprite is pointing toward"""
	# Add sprite art offset back
	var ship_relative = sprite_rotation + sprite_art_offset
	# Convert to world angle
	return ship_relative_to_world_angle(ship_rotation, ship_relative)

# SHIP POSITIONING HELPERS

static func set_ship_facing_target(ship: Node2D, target_position: Vector2):
	"""Orient ship to face a target position"""
	var direction = (target_position - ship.global_position).normalized()
	var world_angle = direction.angle()
	# Subtract 90° because ship sprites point up but we want ship.rotation to be intuitive
	ship.rotation = world_angle - PI/2

static func get_ship_forward_direction(ship: Node2D) -> Vector2:
	"""Get the world direction the ship is facing"""
	return SHIP_FORWARD.rotated(ship.rotation)

static func get_ship_facing_angle(ship: Node2D) -> float:
	"""Get the world angle the ship is facing"""
	return ship.rotation + PI/2

# PDC/TURRET HELPERS

static func set_turret_target_angle(turret: Node2D, parent_ship: Node2D, target_world_angle: float):
	"""Set turret to aim at a world angle"""
	var ship_relative_angle = world_to_ship_relative_angle(parent_ship.rotation, target_world_angle)
	turret.current_rotation = ship_relative_angle
	turret.target_rotation = ship_relative_angle

static func get_turret_world_firing_angle(turret: Node2D, parent_ship: Node2D) -> float:
	"""Get the world angle the turret is currently aiming"""
	return ship_relative_to_world_angle(parent_ship.rotation, turret.current_rotation)

static func calculate_intercept_angle(shooter_pos: Vector2, target_pos: Vector2, target_vel: Vector2, bullet_speed: float) -> float:
	"""Calculate world angle needed to intercept a moving target"""
	var relative_pos = target_pos - shooter_pos
	var distance = relative_pos.length()
	var time_to_target = distance / bullet_speed
	
	var intercept_pos = target_pos + target_vel * time_to_target
	var fire_direction = (intercept_pos - shooter_pos).normalized()
	
	return fire_direction.angle()

# DEBUGGING HELPERS

static func debug_angles(node_name: String, ship_rotation: float, turret_rotation: float, world_target: float):
	"""Print debug info for angle calculations"""
	print("=== ANGLE DEBUG: %s ===" % node_name)
	print("Ship rotation: %.1f°" % rad_to_deg(ship_rotation))
	print("Turret ship-relative: %.1f°" % rad_to_deg(turret_rotation))
	print("Target world angle: %.1f°" % rad_to_deg(world_target))
	print("Turret world angle: %.1f°" % rad_to_deg(ship_relative_to_world_angle(ship_rotation, turret_rotation)))
	print("Angle error: %.1f°" % rad_to_deg(angle_difference(ship_relative_to_world_angle(ship_rotation, turret_rotation), world_target)))
	print("========================")

# VALIDATION HELPERS

static func validate_angle_setup(ship: Node2D, turret: Node2D) -> bool:
	"""Validate that ship and turret angles are set up correctly"""
	var errors = []
	
	# Check ship forward direction
	var ship_forward = get_ship_forward_direction(ship)
	if ship_forward.length() < 0.9:
		errors.append("Ship forward direction invalid")
	
	# Check turret can rotate
	if not turret.has_method("set_target"):
		errors.append("Turret missing set_target method")
	
	if errors.size() > 0:
		print("ROTATION VALIDATION ERRORS:")
		for error in errors:
			print("  - " + error)
		return false
	
	return true

# EXAMPLE USAGE:
"""
# In ship setup:
RotationFramework.set_ship_facing_target(enemy_ship, player_ship.global_position)

# In PDC targeting:
var intercept_angle = RotationFramework.calculate_intercept_angle(
	pdc.global_position, 
	torpedo.global_position, 
	torpedo.velocity_mps, 
	800.0
)
RotationFramework.set_turret_target_angle(pdc, parent_ship, intercept_angle)

# In bullet firing:
var world_angle = RotationFramework.get_turret_world_firing_angle(pdc, parent_ship)
var fire_direction = RotationFramework.world_angle_to_direction(world_angle)
bullet.velocity = fire_direction * bullet_speed

# For debugging:
RotationFramework.debug_angles("PDC_Test", ship.rotation, pdc.current_rotation, target_angle)
"""
