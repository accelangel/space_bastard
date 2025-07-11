# Scripts/Resources/TorpedoType.gd
class_name TorpedoType
extends Resource

enum FlightPattern {
	BASIC,           # Direct intercept (current behavior)
	MULTI_ANGLE,     # Approaches from 45-degree offset
}

@export var torpedo_name: String = "Basic Torpedo"
@export var flight_pattern: FlightPattern = FlightPattern.BASIC

# Physical properties (same as current torpedo)
@export var max_acceleration: float = 1430.0    # 150 Gs in m/s²
@export var lateral_launch_velocity: float = 60.0
@export var lateral_launch_distance: float = 80.0
@export var engine_ignition_delay: float = 1.6
@export var transition_duration: float = 1.6
@export var rotation_transition_duration: float = 3.2
@export var guidance_ramp_duration: float = 0.8

# Multi-angle specific settings
@export_group("Multi-Angle Settings")
@export var approach_angle_offset: float = 45.0  # Degrees from direct path
@export var arc_strength: float = 0.7  # How strongly to curve the path
@export var maintain_offset_distance: float = 500.0  # Meters to maintain offset

# Intercept guidance parameters
@export_group("Guidance Parameters")
@export var navigation_constant: float = 3.0
@export var direct_weight: float = 0.05
@export var speed_threshold: float = 200.0

# Direct intercept PID parameters
@export_group("PID Settings")
@export var kp: float = 800.0
@export var ki: float = 50.0
@export var kd: float = 150.0
