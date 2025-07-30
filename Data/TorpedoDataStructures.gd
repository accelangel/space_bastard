# Scripts/Data/TorpedoDataStructures.gd
extends Resource
class_name TorpedoDataStructures

# Mission Layer Data (1 Hz)
class MissionDirective extends RefCounted:
	var target_node: Node2D = null       # What to attack
	var attack_priority: int = 1         # Engagement priority
	var abort_conditions: Array = []     # When to give up
	var mission_start_time: float = 0.0  # When mission began
	var mission_id: String = ""          # Unique mission identifier

# Guidance Layer Data (10 Hz)
class GuidanceState extends RefCounted:
	var desired_position: Vector2 = Vector2.ZERO    # Where torpedo should be aiming
	var desired_velocity: Vector2 = Vector2.ZERO    # What velocity vector toward target
	var desired_heading: float = 0.0                # Point toward target
	var thrust_level: float = 1.0                   # 1.0 for acceleration, 0.5 for terminal
	var guidance_mode: String = "accelerate"        # "accelerate", "terminal", or "coast"
	var time_to_impact: float = INF                 # Estimated seconds to target
	var target_prediction: Vector2 = Vector2.ZERO   # Where target will be at impact
	var intercept_point: Vector2 = Vector2.ZERO    # Calculated intercept location
	var target_velocity: Vector2 = Vector2.ZERO    # Target's current velocity

# Control Layer Data (60 Hz)
class ControlCommands extends RefCounted:
	var thrust_magnitude: float = 1.0      # 0.0-1.0 thrust level
	var rotation_rate: float = 0.0         # rad/s to orient toward target
	var control_mode: String = "normal"    # "normal", "terminal", "coast"
	var alignment_quality: float = 1.0     # How well aligned with velocity vector
	var desired_rotation: float = 0.0      # Target rotation angle

# Physics State
class TorpedoPhysicsState extends RefCounted:
	var position: Vector2 = Vector2.ZERO
	var velocity: Vector2 = Vector2.ZERO
	var rotation: float = 0.0
	var angular_velocity: float = 0.0
	var mass: float = 100.0  # kg

# Performance Metrics for Tuning
class CycleMetrics extends RefCounted:
	var flight_time: float = 0.0           # Seconds from launch to impact/miss
	var hit_result: bool = false           # true = hit, false = miss
	var miss_distance: float = 0.0         # Distance from target at closest approach
	var terminal_alignment: float = 0.0    # Nose-first quality at impact (0-1)
	var average_speed: float = 0.0         # Average velocity during flight
	var control_smoothness: float = 0.0    # How smooth the control inputs were
	var terminal_velocity: float = 0.0     # Speed at impact/miss
	var max_acceleration: float = 0.0      # Peak acceleration during flight

# Impact/Miss Data for Event System
class ImpactData extends RefCounted:
	var impact_position: Vector2 = Vector2.ZERO
	var impact_velocity: Vector2 = Vector2.ZERO
	var impact_angle: float = 0.0          # Angle between torpedo heading and velocity
	var target_id: String = ""
	var time_of_impact: float = 0.0

class MissData extends RefCounted:
	var closest_approach_distance: float = INF
	var closest_approach_position: Vector2 = Vector2.ZERO
	var miss_reason: String = ""  # "timeout", "lost_track", "out_of_bounds"
	var target_id: String = ""
	var time_of_miss: float = 0.0
