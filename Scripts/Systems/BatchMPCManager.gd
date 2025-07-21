# Scripts/Systems/BatchMPCManager.gd - Enhanced Version
# Singleton that batches all torpedo MPC updates with smart scheduling and caching
extends Node

var gpu_compute: GPUBatchCompute = null
var gpu_available: bool = false

# Torpedo tracking
var pending_torpedoes: Array = []
var active_torpedoes: Dictionary = {}  # torpedo_id -> weakref
var torpedo_metadata: Dictionary = {}  # torpedo_id -> metadata

# Update scheduling
var update_timer: float = 0.0
var update_interval: float = 0.016  # 60 FPS updates
var min_batch_size: int = 1
var max_batch_size: int = 256
var template_count: int = 5

# Simple update frequency
const UPDATE_EVERY_N_FRAMES: int = 5  # Update every 5 frames for all torpedoes

# Emergency update triggers
var emergency_threshold_angle: float = deg_to_rad(30.0)  # Target changed direction > 30°
var emergency_threshold_distance: float = 500.0  # Target moved > 500 pixels

# Performance tracking
var total_batches: int = 0
var total_torpedoes_processed: int = 0
var last_batch_time: float = 0.0
var largest_batch: int = 0
var frame_time_samples: Array = []
var avg_frame_time: float = 0.0

# Template commitment parameters
const MIN_COMMITMENT_TIME: float = 0.5  # Minimum seconds to stick with a template
const TEMPLATE_SWITCH_THRESHOLD: float = 0.2  # Must be 20% better to switch

# Debug
var debug_enabled: bool = true

func _ready():
	print("[BatchMPC] === BATCH MPC MANAGER INITIALIZATION ===")
	
	# Set up as singleton
	set_process(true)
	
	# Initialize GPU compute
	print("[BatchMPC] Step 1: Creating GPUBatchCompute instance...")
	gpu_compute = GPUBatchCompute.new()
	
	print("[BatchMPC] Step 2: Checking GPU availability...")
	gpu_available = gpu_compute.is_available()
	
	print("[BatchMPC] GPU Available: %s" % gpu_available)
	
	if gpu_available:
		print("[BatchMPC] GPU acceleration ready (%s)" % gpu_compute.rd.get_device_name())
	else: 
		print("[BatchMPC] GPU not available - using CPU fallback")
	
	# Listen for game mode changes
	if GameMode:
		GameMode.mode_changed.connect(_on_mode_changed)
	
	print("[BatchMPC] === INITIALIZATION COMPLETE ===")

func _run_test_evaluation() -> bool:
	"""Run a simple test to verify GPU compute actually works"""
	print("[BatchMPC] Test: Creating dummy torpedo and target...")
	
	var test_torpedo_state = {
		"position": Vector2(0, 0),
		"velocity": Vector2(100, 0),
		"orientation": 0.0,
		"angular_velocity": 0.0,
		"max_acceleration": 490.5,
		"max_rotation_rate": deg_to_rad(1080.0)
	}
	
	var test_target_state = {
		"position": Vector2(1000, 0),
		"velocity": Vector2(0, 0)
	}
	
	var test_flight_plan = {
		"type": "straight",
		"side": 0.0,
		"impact_time": 0.0
	}
	
	print("[BatchMPC] Test: Calling evaluate_torpedo_batch...")
	var results = gpu_compute.evaluate_torpedo_batch(
		[test_torpedo_state],
		[test_target_state],
		[test_flight_plan]
	)
	
	if results.size() > 0:
		print("[BatchMPC] Test SUCCESS: Got result with thrust=%.2f, rotation=%.2f" % [
			results[0].thrust, results[0].rotation_rate
		])
		return true
	else:
		print("[BatchMPC] Test FAILED: No results returned from GPU")
		return false

func _on_mode_changed(new_mode: GameMode.Mode):
	if new_mode != GameMode.Mode.BATTLE:
		# Clear all pending updates when leaving battle mode
		clear_all_pending()

func register_torpedo(torpedo: Node2D):
	"""Called by torpedoes to register for batch updates"""
	if not gpu_available:
		return  # Let torpedo handle its own updates
	
	var torpedo_id = torpedo.get("torpedo_id")
	if not torpedo_id:
		push_error("[BatchMPC] Torpedo has no ID!")
		return
	
	# Store weak reference to avoid keeping dead torpedoes
	active_torpedoes[torpedo_id] = weakref(torpedo)
	
	# Initialize metadata - simplified
	torpedo_metadata[torpedo_id] = {
		"last_update_frame": 0,
		"last_target_position": null,
		"last_target_velocity": null,
		# Template commitment tracking
		"current_template_index": -1,
		"template_switch_time": 0.0,
		"template_cost": INF
	}
	
	if debug_enabled:
		print("[BatchMPC] Registered torpedo: %s" % torpedo_id)

func unregister_torpedo(torpedo_id: String):
	"""Called when torpedo is destroyed"""
	active_torpedoes.erase(torpedo_id)
	torpedo_metadata.erase(torpedo_id)
	
	# Remove from pending if queued
	for i in range(pending_torpedoes.size() - 1, -1, -1):
		if pending_torpedoes[i].torpedo_id == torpedo_id:
			pending_torpedoes.remove_at(i)

func request_update(torpedo: Node2D):
	"""Queue a torpedo for batch update - simplified to fixed intervals"""
	if not gpu_available:
		return
	
	var torpedo_id = torpedo.get("torpedo_id")
	if not torpedo_metadata.has(torpedo_id):
		return
	
	var metadata = torpedo_metadata[torpedo_id]
	var current_frame = Engine.get_physics_frames()
	
	# Simple frame-based update check
	var frames_since_last = current_frame - metadata.last_update_frame
	if frames_since_last < UPDATE_EVERY_N_FRAMES:
		return  # Skip this update
	
	# Check for emergency update conditions
	var needs_emergency_update = check_emergency_conditions(torpedo, metadata)
	
	# Simple priority - emergency updates get priority, otherwise all equal
	var priority = 1.0
	if needs_emergency_update:
		priority = 100.0
	
	# Check if already pending
	for pending in pending_torpedoes:
		if pending.torpedo == torpedo:
			pending.priority = max(pending.priority, priority)
			return
	
	# Add to pending queue
	pending_torpedoes.append({
		"torpedo": torpedo,
		"torpedo_id": torpedo_id,
		"priority": priority,
		"request_time": Time.get_ticks_msec() / 1000.0,
		"emergency": needs_emergency_update
	})

func check_emergency_conditions(torpedo: Node2D, metadata: Dictionary) -> bool:
	"""Check if torpedo needs emergency update"""
	var target = torpedo.get("target_node")
	if not target or not is_instance_valid(target):
		return false
	
	# Check if target has moved significantly
	if metadata.last_target_position != null:
		var position_change = target.global_position.distance_to(metadata.last_target_position)
		if position_change > emergency_threshold_distance:
			return true
		
		# Check if target velocity changed significantly
		if target.has_method("get_velocity_mps"):
			var current_velocity = target.get_velocity_mps()
			if metadata.last_target_velocity != null:
				var velocity_angle_before = metadata.last_target_velocity.angle()
				var velocity_angle_now = current_velocity.angle()
				var angle_change = abs(angle_difference(velocity_angle_before, velocity_angle_now))
				if angle_change > emergency_threshold_angle:
					return true
	
	return false

func _process(delta):
	if not gpu_available:
		return
	
	update_timer += delta
	
	# Track frame time for performance monitoring
	var frame_start = Time.get_ticks_usec()
	
	# Process batch at update interval
	if update_timer >= update_interval:
		update_timer = 0.0
		process_pending_batch()
	
	# Update performance metrics
	var frame_time = (Time.get_ticks_usec() - frame_start) / 1000.0
	frame_time_samples.append(frame_time)
	if frame_time_samples.size() > 60:
		frame_time_samples.pop_front()
	
	# Calculate average frame time
	if frame_time_samples.size() > 0:
		var sum = 0.0
		for sample in frame_time_samples:
			sum += sample
		avg_frame_time = sum / frame_time_samples.size()
	
	# Clean up dead references periodically
	if Engine.get_physics_frames() % 300 == 0:  # Every 5 seconds at 60 FPS
		cleanup_dead_references()

func process_pending_batch():
	"""Process all pending torpedoes in one GPU batch"""
	if pending_torpedoes.is_empty():
		return
	
	var start_time = Time.get_ticks_usec()
	
	# Sort by priority (highest first)
	pending_torpedoes.sort_custom(func(a, b): return a.priority > b.priority)
	
	# Prepare batch data
	var batch_torpedoes = []
	var batch_states = []
	var batch_targets = []
	var batch_flight_plans = []
	
	# Process up to max_batch_size torpedoes
	var count = min(pending_torpedoes.size(), max_batch_size)
	
	for i in range(count):
		var pending = pending_torpedoes[i]
		var torpedo = pending.torpedo
		
		# Validate torpedo still exists
		if not is_instance_valid(torpedo) or torpedo.get("marked_for_death"):
			continue
		
		# Update metadata
		var metadata = torpedo_metadata.get(pending.torpedo_id, {})
		metadata.last_update_frame = Engine.get_physics_frames()
		
		# Get torpedo state
		var state = {
			"position": torpedo.global_position,
			"velocity": torpedo.get("velocity_mps"),
			"orientation": torpedo.get("orientation"),
			"angular_velocity": torpedo.get("angular_velocity"),
			"max_acceleration": torpedo.get("max_acceleration"),
			"max_rotation_rate": torpedo.get("max_rotation_rate")
		}
		
		# Get target state
		var target = torpedo.get("target_node")
		if not target or not is_instance_valid(target):
			continue
			
		var target_state = {
			"position": target.global_position,
			"velocity": target.get("velocity_mps") if target.has_method("get_velocity_mps") else Vector2.ZERO
		}
		
		# Update last known target state
		metadata.last_target_position = target.global_position
		metadata.last_target_velocity = target_state.velocity
		
		# Get flight plan data
		var flight_plan = {
			"type": torpedo.flight_plan_type if "flight_plan_type" in torpedo else "straight",
			"side": 0.0,
			"impact_time": 0.0
		}
		
		# For multi-angle, determine side
		if flight_plan.type == "multi_angle":
			var launch_side = torpedo.launch_side if "launch_side" in torpedo else 1
			flight_plan.side = float(launch_side)
		
		# For simultaneous, get assigned angle and impact time
		elif flight_plan.type == "simultaneous":
			var flight_data = torpedo.flight_plan_data if "flight_plan_data" in torpedo else {}
			if flight_data.has("impact_angle"):
				flight_plan.side = flight_data.impact_angle  # Using side field for angle
			if flight_data.has("impact_time"):
				flight_plan.impact_time = flight_data.impact_time
		
		batch_torpedoes.append(torpedo)
		batch_states.append(state)
		batch_targets.append(target_state)
		batch_flight_plans.append(flight_plan)
	
	# Clear processed items
	pending_torpedoes = pending_torpedoes.slice(count)
	
	if batch_torpedoes.is_empty():
		return
	
	# Process batch on GPU
	var results = gpu_compute.evaluate_torpedo_batch(batch_states, batch_targets, batch_flight_plans)
	
	# Apply results with template commitment
	for i in range(batch_torpedoes.size()):
		var torpedo = batch_torpedoes[i]
		if is_instance_valid(torpedo) and i < results.size():
			var torpedo_id = torpedo.get("torpedo_id")
			var metadata = torpedo_metadata.get(torpedo_id, {})
			var current_time = Time.get_ticks_msec() / 1000.0
		
			# Get the proposed template and cost from GPU results
			var proposed_template = int(results[i].get("template_index", 0))
			var proposed_cost = results[i].get("cost", INF)
			var current_template = metadata.get("current_template_index", -1)
			var time_since_switch = current_time - metadata.get("template_switch_time", 0.0)
		
			# Check if we should switch templates
			var should_switch = false
		
			if current_template == -1:
				# First time - always accept
				should_switch = true
			elif time_since_switch < MIN_COMMITMENT_TIME:
				# Still in commitment period - keep current template
				should_switch = false
			else:
				# Check if new template is significantly better
				var current_cost = metadata.get("template_cost", INF)
				var improvement_ratio = (current_cost - proposed_cost) / current_cost
			
				if improvement_ratio > TEMPLATE_SWITCH_THRESHOLD:
					should_switch = true
					if debug_enabled:
						print("[BatchMPC] Torpedo %s switching template %d->%d (%.1f%% improvement)" % [
							torpedo_id, current_template, proposed_template, improvement_ratio * 100
						])
		
			# Apply control based on decision
			if should_switch:
				# Accept new template
				metadata["current_template_index"] = proposed_template
				metadata["template_switch_time"] = current_time
				metadata["template_cost"] = proposed_cost
			
				# Apply the new control
				if torpedo.has_method("apply_mpc_control"):
					torpedo.apply_mpc_control(results[i])
			else:
				# Stick with current template - recalculate control for it
				if current_template >= 0 and current_template < template_count:
					# We need to get the control for the committed template
					# For now, we'll use the last known control
					# In a more sophisticated system, we'd recalculate for the committed template
					if torpedo.has_method("apply_mpc_control"):
						# Modify the result to use the committed template
						var committed_result = results[i].duplicate()
						committed_result["template_index"] = current_template
						torpedo.apply_mpc_control(committed_result)
		
			# Update metadata
			torpedo_metadata[torpedo_id] = metadata
	
	# Update stats
	var batch_time = (Time.get_ticks_usec() - start_time) / 1000.0
	last_batch_time = batch_time
	total_batches += 1
	total_torpedoes_processed += batch_torpedoes.size()
	largest_batch = max(largest_batch, batch_torpedoes.size())

func cleanup_dead_references():
	"""Remove dead torpedo references"""
	var dead_ids = []
	
	for id in active_torpedoes:
		var ref = active_torpedoes[id]
		if not ref.get_ref():
			dead_ids.append(id)
	
	for id in dead_ids:
		active_torpedoes.erase(id)
		torpedo_metadata.erase(id)
	
	if dead_ids.size() > 0 and debug_enabled:
		print("[BatchMPC] Cleaned up %d dead torpedo references" % dead_ids.size())

func clear_all_pending():
	"""Clear all pending updates"""
	pending_torpedoes.clear()
	update_timer = 0.0

func angle_difference(from: float, to: float) -> float:
	"""Calculate shortest angle difference"""
	var diff = to - from
	while diff > PI:
		diff -= TAU
	while diff < -PI:
		diff += TAU
	return diff

func get_stats() -> Dictionary:
	# Count template distribution
	var template_counts = {}
	for i in range(5):  # 5 templates
		template_counts[i] = 0

	for id in torpedo_metadata:
		var meta = torpedo_metadata[id]
		var template = meta.get("current_template_index", -1)
		if template >= 0 and template < 5:
			template_counts[template] += 1

	return {
		"active_torpedoes": active_torpedoes.size(),
		"pending_updates": pending_torpedoes.size(),
		"total_batches": total_batches,
		"total_processed": total_torpedoes_processed,
		"last_batch_time_ms": last_batch_time,
		"largest_batch": largest_batch,
		"gpu_available": gpu_available,
		"avg_frame_time_ms": avg_frame_time,
		"template_distribution": template_counts
	}
