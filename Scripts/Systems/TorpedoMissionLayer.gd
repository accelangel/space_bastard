# Scripts/Systems/TorpedoMissionLayer.gd
extends Node
class_name TorpedoMissionLayer

var torpedo: StandardTorpedo

func configure(torpedo_ref: StandardTorpedo):
	torpedo = torpedo_ref

func update_mission(current_directive: TorpedoDataStructures.MissionDirective) -> TorpedoDataStructures.MissionDirective:
	# Simple mission: maintain target assignment
	
	# Check if target is still valid
	if not is_valid_target(current_directive.target_node):
		# Target lost - could implement target reacquisition here
		current_directive.target_node = null
		current_directive.abort_conditions.append("target_lost")
	
	# For standard torpedo, mission is simply "attack assigned target"
	# No complex mission planning needed
	
	return current_directive

func is_valid_target(target: Node2D) -> bool:
	if not target:
		return false
	if not is_instance_valid(target):
		return false
	if not target.is_inside_tree():
		return false
	if target.get("marked_for_death"):
		return false
	if target.get("is_alive") == false:
		return false
	return true
