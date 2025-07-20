# Scripts/Systems/BatchMPCManager.gd - Enhanced Version
# Singleton that batches all torpedo MPC updates with smart scheduling and caching
extends Node

var gpu_compute: GPUBatchCompute = null
var gpu_available: bool = false

# Torpedo tracking
var pending_torpedoes: Array = []
var active_torpedoes: Dictionary = {}  # torpedo_id -> weakref
var torpedo_metadata: Dictionary = {}  # torpedo_id -> metadata

# Trajectory caching
var trajectory_cache: Dictionary = {}  # torpedo_id -> cached trajectory data
var cache_hit_count: int = 0
var cache_miss_count: int = 0

# Update scheduling
var update_timer: float = 0.0
var update_interval: float = 0.016  # 60 FPS updates
var min_batch_size: int = 1
var max_batch_size: int = 256

# Smart scheduling parameters
const NEAR_IMPACT_DISTANCE: float = 2000.0
const MEDIUM_RANGE_DISTANCE: float = 10000.0
const NEAR_IMPACT_UPDATE_RATE: int = 1    # Every frame
const MEDIUM_RANGE_UPDATE_RATE: int = 3   # Every 3 frames
const FAR_RANGE_UPDATE_RATE: int = 5      # Every 5 frames
const LAUNCH_BOOST_FRAMES: int = 10       # High priority for first 10 frames

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

# Template evolution (if enabled)
var template_evolution_enabled: bool = true
var template_evolution_timer: float = 0.0
var template_evolution_interval: float = 1.0  # Evolve every second

# Debug
var debug_enabled: bool = true
var performance_overlay: Node = null

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
		print("[BatchMPC] SUCCESS: GPU batch processing available!")
		print("[BatchMPC] Smart scheduling enabled - adaptive update rates")
		print("[BatchMPC] Trajectory caching enabled")
		
		# Try a test evaluation to make sure it really works
		print("[BatchMPC] Running test evaluation...")
		var test_success = _run_test_evaluation()
		if not test_success:
			print("[BatchMPC] WARNING: Test evaluation failed, disabling GPU")
			gpu_available = false
	else:
		print("[BatchMPC] FAILED: GPU not available - check GPUBatchCompute output above")
		print("[BatchMPC] Torpedoes will need to use individual CPU fallback")
	
	# Initialize template evolution
	if template_evolution_enabled and gpu_available:
		var evolution_system = GPUTemplateEvolution.new()
		set_meta("evolution_system", evolution_system)
		print("[BatchMPC] Template evolution system initialized")
	
	# Listen for game mode changes
	if GameMode:
		GameMode.mode_changed.connect(_on_mode_changed)
	
	# Create performance overlay
	if debug_enabled:
		create_performance_overlay()
	
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
		# Clear cache
		trajectory_cache.clear()
		cache_hit_count = 0
		cache_miss_count = 0

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
	
	# Initialize metadata for smart scheduling
	torpedo_metadata[torpedo_id] = {
		"launch_frame": Engine.get_physics_frames(),
		"last_update_frame": 0,
		"update_priority": 10.0,
		"last_target_position": null,
		"last_target_velocity": null,
		"frames_since_update": 0,
		"scheduled_update_rate": NEAR_IMPACT_UPDATE_RATE
	}
	
	# Assign evolved template if evolution is enabled
	if template_evolution_enabled:
		assign_template_to_torpedo(torpedo)
	
	if debug_enabled:
		print("[BatchMPC] Registered torpedo: %s" % torpedo_id)

func unregister_torpedo(torpedo_id: String):
	"""Called when torpedo is destroyed"""
	active_torpedoes.erase(torpedo_id)
	torpedo_metadata.erase(torpedo_id)
	trajectory_cache.erase(torpedo_id)
	
	# Remove from pending if queued
	for i in range(pending_torpedoes.size() - 1, -1, -1):
		if pending_torpedoes[i].torpedo_id == torpedo_id:
			pending_torpedoes.remove_at(i)

func request_update(torpedo: Node2D, base_priority: float = 1.0):
	"""Queue a torpedo for batch update with smart scheduling"""
	if not gpu_available:
		return
	
	var torpedo_id = torpedo.get("torpedo_id")
	if not torpedo_metadata.has(torpedo_id):
		return
	
	var metadata = torpedo_metadata[torpedo_id]
	var current_frame = Engine.get_physics_frames()
	
	# Check if update is needed based on smart scheduling
	var frames_since_last = current_frame - metadata.last_update_frame
	if frames_since_last < metadata.scheduled_update_rate:
		return  # Skip this update
	
	# Check for emergency update conditions
	var needs_emergency_update = check_emergency_conditions(torpedo, metadata)
	
	# Calculate dynamic priority
	var priority = calculate_dynamic_priority(torpedo, metadata, base_priority)
	
	if needs_emergency_update:
		priority *= 100.0  # Boost priority massively
	
	# Check trajectory cache
	var cache_key = generate_cache_key(torpedo)
	if trajectory_cache.has(cache_key) and not needs_emergency_update:
		var cached_trajectory = trajectory_cache[cache_key]
		if is_trajectory_still_valid(cached_trajectory, torpedo):
			# Use cached trajectory
			if torpedo.has_method("apply_cached_trajectory"):
				torpedo.apply_cached_trajectory(cached_trajectory)
			cache_hit_count += 1
			return
	
	cache_miss_count += 1
	
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
		"cache_key": cache_key,
		"emergency": needs_emergency_update
	})
	
	metadata.frames_since_update += 1

func calculate_dynamic_priority(torpedo: Node2D, metadata: Dictionary, base_priority: float) -> float:
	"""Calculate update priority based on multiple factors"""
	var priority = base_priority
	
	# Distance to target
	var target = torpedo.get("target_node")
	if target and is_instance_valid(target):
		var distance = torpedo.global_position.distance_to(target.global_position)
		
		# Update scheduled rate based on distance
		if distance < NEAR_IMPACT_DISTANCE:
			priority *= 10.0
			metadata.scheduled_update_rate = NEAR_IMPACT_UPDATE_RATE
		elif distance < MEDIUM_RANGE_DISTANCE:
			priority *= 5.0
			metadata.scheduled_update_rate = MEDIUM_RANGE_UPDATE_RATE
		else:
			metadata.scheduled_update_rate = FAR_RANGE_UPDATE_RATE
	
	# Launch boost - high priority for newly launched torpedoes
	var frames_since_launch = Engine.get_physics_frames() - metadata.launch_frame
	if frames_since_launch < LAUNCH_BOOST_FRAMES:
		priority *= 3.0
	
	# Penalty for recent updates
	if metadata.frames_since_update < 2:
		priority *= 0.5
	
	# Boost for long time without update
	if metadata.frames_since_update > 10:
		priority *= 2.0
	
	return priority

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

func generate_cache_key(torpedo: Node2D) -> String:
	"""Generate cache key based on torpedo and target state"""
	var target = torpedo.get("target_node")
	if not target:
		return ""
	
	# Simple cache key - could be more sophisticated
	var target_pos = target.global_position
	var grid_x = int(target_pos.x / 100.0)
	var grid_y = int(target_pos.y / 100.0)
	
	return "%s_%d_%d" % [torpedo.get("flight_plan_type"), grid_x, grid_y]

func is_trajectory_still_valid(cached_trajectory: Dictionary, torpedo: Node2D) -> bool:
	"""Check if cached trajectory is still valid"""
	var age = Time.get_ticks_msec() / 1000.0 - cached_trajectory.timestamp
	if age > 0.5:  # Cache expires after 0.5 seconds
		return false
	
	# Check if torpedo has deviated too much from cached trajectory
	var expected_position = cached_trajectory.expected_position
	var actual_position = torpedo.global_position
	var deviation = expected_position.distance_to(actual_position)
	
	return deviation < 200.0  # 200 pixel tolerance

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
	
	# Template evolution
	if template_evolution_enabled:
		template_evolution_timer += delta
		if template_evolution_timer >= template_evolution_interval:
			template_evolution_timer = 0.0
			evolve_templates()
	
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
	
	# Update performance overlay
	if performance_overlay:
		update_performance_overlay()
	
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
		metadata.frames_since_update = 0
		
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
			"type": torpedo.get("flight_plan_type", "straight"),
			"side": 0.0,
			"impact_time": 0.0
		}
		
		# For multi-angle, determine side
		if flight_plan.type == "multi_angle":
			var launch_side = torpedo.get("launch_side", 1)
			flight_plan.side = float(launch_side)
		
		# For simultaneous, get assigned angle and impact time
		elif flight_plan.type == "simultaneous":
			var flight_data = torpedo.get("flight_plan_data", {})
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
	
	# Apply results and cache trajectories
	for i in range(batch_torpedoes.size()):
		var torpedo = batch_torpedoes[i]
		if is_instance_valid(torpedo) and i < results.size():
			# Let torpedo apply the control
			if torpedo.has_method("apply_mpc_control"):
				torpedo.apply_mpc_control(results[i])
			
			# Cache the trajectory
			var cache_key = generate_cache_key(torpedo)
			if cache_key != "":
				trajectory_cache[cache_key] = {
					"timestamp": Time.get_ticks_msec() / 1000.0,
					"control": results[i],
					"expected_position": torpedo.global_position + torpedo.get("velocity_mps") * 0.1
				}
	
	# Update stats
	var batch_time = (Time.get_ticks_usec() - start_time) / 1000.0
	last_batch_time = batch_time
	total_batches += 1
	total_torpedoes_processed += batch_torpedoes.size()
	largest_batch = max(largest_batch, batch_torpedoes.size())
	
	if debug_enabled:
		print("[BatchMPC] Processed %d torpedoes in %.2fms (Cache hits: %d/%d)" % [
			batch_torpedoes.size(), batch_time, cache_hit_count, cache_hit_count + cache_miss_count
		])

func evolve_templates():
	"""Trigger template evolution on GPU"""
	var evolution_system = get_meta("evolution_system") if has_meta("evolution_system") else null
	if evolution_system and evolution_system.has_method("evolve_population"):
		# Evolve for each trajectory type
		evolution_system.evolve_population("straight")
		
		# Get best templates and update GPU compute
		if gpu_compute and gpu_compute.has_method("update_templates"):
			var best_templates = evolution_system.get_best_templates(20)
			gpu_compute.update_templates(best_templates)
			
			if debug_enabled:
				var stats = evolution_system.get_evolution_stats()
				print("[BatchMPC] Template evolution - Gen: %d, Avg Fitness: %.3f, Best: %.3f" % [
					stats.generation, stats.avg_fitness, stats.best_fitness
				])
		else:
			if debug_enabled:
				print("[BatchMPC] Template evolution triggered (no update method)")
	else:
		if debug_enabled:
			print("[BatchMPC] Template evolution triggered (no evolution system)")

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
		trajectory_cache.erase(id)
	
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

# Performance monitoring UI
func create_performance_overlay():
	"""Create debug overlay for performance monitoring"""
	var canvas_layer = CanvasLayer.new()
	canvas_layer.name = "MPCPerformanceOverlay"
	add_child(canvas_layer)
	
	var panel = Panel.new()
	panel.name = "PerformancePanel"
	panel.set_position(Vector2(10, 100))
	panel.set_size(Vector2(300, 200))
	panel.modulate.a = 0.8
	
	var label = RichTextLabel.new()
	label.name = "PerformanceLabel"
	label.set_position(Vector2(10, 10))
	label.set_size(Vector2(280, 180))
	label.add_theme_font_size_override("normal_font_size", 11)
	label.add_theme_color_override("default_color", Color.WHITE)
	panel.add_child(label)
	
	canvas_layer.add_child(panel)
	performance_overlay = label

func update_performance_overlay():
	"""Update performance overlay with current stats"""
	if not performance_overlay:
		return
	
	var active_count = 0
	for id in active_torpedoes:
		if active_torpedoes[id].get_ref():
			active_count += 1
	
	var cache_total = cache_hit_count + cache_miss_count
	var cache_rate = 0.0
	if cache_total > 0:
		cache_rate = float(cache_hit_count) / float(cache_total) * 100.0
	
	var text = "[b]GPU MPC Performance[/b]\n"
	text += "─".repeat(25) + "\n"
	text += "Active Torpedoes: %d\n" % active_count
	text += "Pending Updates: %d\n" % pending_torpedoes.size()
	text += "Batch Time: %.2fms\n" % last_batch_time
	text += "Avg Frame Time: %.2fms\n" % avg_frame_time
	text += "Largest Batch: %d\n" % largest_batch
	text += "\n[b]Cache Performance[/b]\n"
	text += "Hit Rate: %.1f%%\n" % cache_rate
	text += "Total Hits: %d\n" % cache_hit_count
	text += "\n[b]Smart Scheduling[/b]\n"
	
	# Count torpedoes by update rate
	var near_count = 0
	var medium_count = 0
	var far_count = 0
	
	for id in torpedo_metadata:
		var meta = torpedo_metadata[id]
		match meta.scheduled_update_rate:
			NEAR_IMPACT_UPDATE_RATE:
				near_count += 1
			MEDIUM_RANGE_UPDATE_RATE:
				medium_count += 1
			FAR_RANGE_UPDATE_RATE:
				far_count += 1
	
	text += "Near (1f): %d\n" % near_count
	text += "Medium (3f): %d\n" % medium_count
	text += "Far (5f): %d\n" % far_count
	
	performance_overlay.clear()
	performance_overlay.append_text(text)

func get_stats() -> Dictionary:
	return {
		"active_torpedoes": active_torpedoes.size(),
		"pending_updates": pending_torpedoes.size(),
		"total_batches": total_batches,
		"total_processed": total_torpedoes_processed,
		"last_batch_time_ms": last_batch_time,
		"largest_batch": largest_batch,
		"gpu_available": gpu_available,
		"cache_hit_rate": float(cache_hit_count) / float(cache_hit_count + cache_miss_count) if (cache_hit_count + cache_miss_count) > 0 else 0.0,
		"avg_frame_time_ms": avg_frame_time
	}

func report_template_performance(template_index: int, hit_success: bool, trajectory_quality: float):
	"""Report template performance for evolution feedback"""
	var evolution_system = get_meta("evolution_system") if has_meta("evolution_system") else null
	if evolution_system and evolution_system.has_method("update_template_fitness"):
		evolution_system.update_template_fitness(template_index, hit_success, trajectory_quality)

func toggle_performance_overlay():
	"""Toggle visibility of performance overlay"""
	if performance_overlay and performance_overlay.get_parent():
		performance_overlay.get_parent().visible = !performance_overlay.get_parent().visible

func assign_template_to_torpedo(torpedo: Node2D) -> int:
	"""Assign an evolved template to a torpedo and return its index"""
	var evolution_system = get_meta("evolution_system") if has_meta("evolution_system") else null
	if evolution_system and evolution_system.has_method("select_template_for_torpedo"):
		var template = evolution_system.select_template_for_torpedo()
		if template.has("template_index"):
			# Tell torpedo which template it's using
			if torpedo.has_method("set_template_index"):
				torpedo.set_template_index(template.template_index)
			return template.template_index
	return -1
