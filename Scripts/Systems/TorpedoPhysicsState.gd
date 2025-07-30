# Scripts/Systems/TorpedoPhysicsState.gd
extends Node
class_name TorpedoPhysicsStateManager

# This is a utility class for managing torpedo physics state
# The actual physics state is stored in TorpedoDataStructures.TorpedoPhysicsState

static func create_from_torpedo(torpedo: StandardTorpedo) -> TorpedoDataStructures.TorpedoPhysicsState:
	var state = TorpedoDataStructures.TorpedoPhysicsState.new()
	state.position = torpedo.global_position
	state.velocity = torpedo.velocity_mps / WorldSettings.meters_per_pixel
	state.rotation = torpedo.rotation
	state.mass = torpedo.current_mass
	return state

static func apply_to_torpedo(state: TorpedoDataStructures.TorpedoPhysicsState, torpedo: StandardTorpedo):
	torpedo.global_position = state.position
	torpedo.velocity_mps = state.velocity * WorldSettings.meters_per_pixel
	torpedo.rotation = state.rotation
	torpedo.current_mass = state.mass
