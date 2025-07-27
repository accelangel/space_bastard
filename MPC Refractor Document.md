# MPC Torpedo System Refactoring Plan v9.0 - Physics-First Implementation with Clean Data Architecture

## The Problem

The current MPC system is overcomplicated and fights against physics. Torpedoes oscillate between templates, can't hit stationary targets, and the "MPC" is really just template selection. The system tries to recalculate everything every frame instead of committing to a plan and following it smoothly. Templates are parameter sets, not actual trajectories, leading to jerky, unpredictable motion. Most critically, the data flow is tangled with circular dependencies, no clear ownership boundaries, and systems trying to do too many things at once.

### The Fundamental Physics Challenge

In space combat with forward-only thrust, the relationship between velocity and maneuverability is brutal:
- **Turn radius = v²/a_lateral**
- At 2,000 m/s with 150G (1,471.5 m/s²): radius = 2.7 km
- At 20,000 m/s: radius = 272 km
- At 91,000 m/s: radius = 5,633 km

Why this matters: At 4,000 km engagement range, a torpedo trying to achieve a 90° approach angle while traveling at 91,000 m/s would need to start turning before it even launches! The turn radius (5,633 km) is larger than the entire engagement distance. This isn't a control problem - it's physically impossible.

### The Velocity Alignment Paradox

The old system tried to solve "sideways torpedoes" by adding alignment weights that fought against trajectory following. This created an unsolvable conflict:
- To change direction quickly, torpedo must rotate away from velocity vector
- To minimize PDC cross-section, torpedo must align with velocity vector
- These goals are mutually exclusive at high speeds

The real problem wasn't alignment - it was trying to execute impossible trajectories.

### The Data Architecture Problem

Beyond physics, the current system violates fundamental software architecture principles:
- **No Single Source of Truth**: Multiple systems track the same data differently
- **Circular Dependencies**: Torpedoes call managers which call planners which modify torpedoes
- **Mixed Responsibilities**: Systems try to handle planning, execution, and analysis simultaneously
- **Push-Based Chaos**: Every torpedo independently requests updates, causing stampedes

## The Solution

A true layered guidance system with clean data architecture where GPU-based trajectory planning (Layer 1) generates physically-achievable waypoint paths with velocity profiles through a pull-based update system, and simple proportional navigation (Layer 2) smoothly flies through them matching both position and velocity targets. When physics demands it, we employ flip-and-burn maneuvers - the same technique The Expanse's ships use for navigation. All systems follow single-responsibility principles with unidirectional data flow.

### The Flip-and-Burn Revolution

Flip-and-burn isn't a special case - it's the fundamental solution to high-velocity navigation:

1. **Acceleration Phase**: Thrust hard toward desired position (100-150G)
2. **Flip Phase**: Rotate 180° while coasting (2-3 seconds)
3. **Deceleration Phase**: Thrust retrograde to reduce velocity to manageable levels
4. **Maneuver Phase**: Execute desired trajectory at velocity where turn radius allows it

Example: To approach from 90° at 4,000 km:
- Without flip-burn: Need to arc with 5,633 km radius (impossible - larger than battlefield!)
- With flip-burn: Decelerate to 2,000 m/s, arc with 2.7 km radius (easy!)

This isn't slower - it's the ONLY way to achieve sharp angle changes at combat velocities.

### Clean Data Architecture Principles

The V9 architecture follows these core principles:

1. **Single Responsibility**: Each system does exactly one thing
2. **Single Source of Truth**: One authoritative owner for each piece of data
3. **No Cross-Dependencies**: Systems communicate through events, not direct calls
4. **Pull-Based Updates**: Centralized scheduling prevents update stampedes
5. **Unidirectional Data Flow**: Data flows in one direction through the pipeline

## Critical Design Consideration: Terminal Alignment (Natural Solution)

### The Problem Solves Itself

With physics-based trajectories and velocity management:

1. **During Burns**: Torpedo naturally points along velocity vector (thrust = velocity change)
2. **During Flips**: Brief misalignment at maximum range from threats
3. **During Curves**: Velocity low enough that rotation rate can track naturally
4. **Terminal Phase**: Proper trajectory planning ensures nose-first approach

**No alignment weights needed!** Natural physics creates natural alignment.

## Physics Constraints & Requirements

### What We Accept
- **Forward-only thrust** (torpedoes can't thrust sideways or backwards)
- **Continuous acceleration** (30G baseline, up to 150G for maneuvers)
- **No arbitrary speed limit** (only physics limits and target requirements)
- **20-100% throttle range** (no reverse thrust except via flip maneuver)
- **Turn radius = v²/a** (emerges from physics, not programmed)
- **Lateral launch ejection** (all torpedoes launch sideways from tubes)
- **GPU compute required** (no CPU fallback - this is non-negotiable)

### What We DON'T Want
- Arbitrary speed caps (old 2000 m/s limit)
- Constant throttle cutting that wastes efficiency
- Impossible turns that physics won't allow
- Competing control objectives (alignment vs tracking)
- Different physics for different torpedo types
- Multiple flip-burns per approach (maximum 1, rarely 2)
- CPU trajectory calculations (too slow to be usable)

## Core Data Architecture

### Pull-Based Update System

The V9 architecture uses a **pull-based update system** where BatchMPCManager owns the update schedule:

```
Every 1-3Hz (based on time-to-impact):
BatchMPCManager timer tick →
BatchMPCManager collects all torpedo states →
BatchMPCManager validates states →
BatchMPCManager sends batch to TrajectoryPlanner →
TrajectoryPlanner executes GPU computation →
GPU returns new waypoints for all torpedoes →
BatchMPCManager applies waypoints to each torpedo →
BatchMPCManager emits "waypoints_updated" signal →
Torpedoes continue following updated waypoints
```

This eliminates update stampedes, ensures perfect GPU batching, and maintains predictable performance.

### System Responsibilities

**BatchMPCManager** (Scheduling & Coordination):
- Owns the 1-3Hz update schedule
- Determines update frequency based on time-to-impact
- Collects and validates all torpedo states
- Batches GPU requests efficiently
- Applies results back to torpedoes
- Emits waypoint update events
- **Does NOT**: Generate trajectories, understand physics, or make tactical decisions

**TrajectoryPlanner** (GPU Trajectory Generation):
- Owns the GPU compute shader interface
- Generates physically-valid waypoints
- Validates trajectory feasibility
- Manages GPU resources and buffers
- **Does NOT**: Schedule updates, track individual torpedoes, or apply results

**TorpedoBase** (State & Execution):
- Stores current waypoints
- Maintains physics state (position, velocity, orientation)
- Executes waypoint following via ProportionalNavigation
- **Does NOT**: Request updates, generate trajectories, or modify waypoints

**ProportionalNavigation** (Moment-to-Moment Control):
- Calculates thrust and rotation to follow waypoints
- Matches both position and velocity targets
- Handles special maneuvers (flips)
- **Does NOT**: Plan trajectories, modify waypoints, or make strategic decisions

**TorpedoVisualizer** (Pure Observer):
- Listens for waypoint update events
- Reads torpedo states for visualization
- Renders trails and waypoint markers
- **Does NOT**: Modify any game state

### Zero-Trust Validation

All validation happens in **BatchMPCManager** during state collection:

```gdscript
func collect_torpedo_states() -> Array:
    var valid_states = []
    var torpedoes = get_tree().get_nodes_in_group("torpedoes")
    
    for torpedo in torpedoes:
        # Zero-trust validation
        if not is_instance_valid(torpedo):
            continue
        if not torpedo.is_inside_tree():
            continue
        if torpedo.get("marked_for_death"):
            continue
        if not validate_physics_state(torpedo):
            continue
            
        valid_states.append(extract_torpedo_state(torpedo))
    
    return valid_states
```

This single validation point protects the entire pipeline from invalid data.

### Event-Based Communication

Systems communicate through signals, not direct method calls:

```gdscript
# BatchMPCManager emits
signal waypoints_updated(torpedo_id: String, waypoints: Array)
signal batch_update_started()
signal batch_update_completed(torpedo_count: int)

# TorpedoVisualizer listens
func _ready():
    var batch_manager = get_node("/root/BatchMPCManager")
    batch_manager.waypoints_updated.connect(_on_waypoints_updated)
```

## Files to DELETE

### Complete Removal
- `BatchMPCManager.gd` - replaced by new pull-based version
- `GPUBatchCompute.gd` - replaced by cleaner GPU planner
- `MPCController.gd` - no CPU fallback needed
- `MPCTuner.gd` - replaced by manual tuning system
- `MPCTuningObserver.gd` - replaced by simpler feedback system
- `mpc_trajectory_batch.glsl` - replaced with cleaner shader
- `TestComputeShader.gd` - test file no longer needed
- `test_compute.glsl` - test shader no longer needed
- `test_compute_shader.glsl` - test shader no longer needed

### Heavy Modification
- `TorpedoMPC.gd` - becomes SmartTorpedo.gd (90% rewrite)

### NEW Files to Create
- `ProportionalNavigation.gd` -  Layer 2 guidance system
- `TrajectoryPlanner.gd` -  GPU-based Layer 1 trajectory planning
- `ManualTuningParameters.gd` -  Autoload singleton for parameters
- `ManualTuningPanel.gd` -  UI for real-time tuning
- `trajectory_planning_v9.glsl` -  New GPU compute shader

## New Architecture

### **TorpedoBase.gd**
**Why**: Shared foundation prevents code duplication and ensures consistent physics, launch behavior, and velocity tracking

Provides ALL torpedoes with:
- Core physics state (position, velocity, orientation)
- Thrust and rotation application
- **Lateral launch system** (unchanged from v6.1)
- Trail rendering with quality-based coloring
- Enhanced waypoint structure with velocity profiles:

```gdscript
class Waypoint:
    var position: Vector2
    var velocity_target: float        # Desired speed at this waypoint in m/s
    var velocity_tolerance: float     # How close to target velocity (default 500 m/s)
    var maneuver_type: String        # "cruise", "flip", "burn", "curve", "terminal"
    var thrust_limit: float          # 0.0-1.0, allows fine control per segment
    
    func should_accept(torpedo_pos: Vector2, torpedo_vel: float) -> bool:
        var pos_error = position.distance_to(torpedo_pos) * WorldSettings.meters_per_pixel
        var vel_error = abs(velocity_target - torpedo_vel)
        
        # Position acceptance remains the same
        if pos_error < acceptance_radius_meters:
            return true
            
        # Also accept if we're close in velocity and moving toward waypoint
        if vel_error < velocity_tolerance and is_moving_toward_waypoint(torpedo_pos, position):
            return true
            
        return false
```

Trail Quality Rendering:
```gdscript
var trail_quality: float = 0.0
var trail_quality_factors = {
    "alignment_error": 0.3,      # 30% weight
    "velocity_matching": 0.3,    # 30% weight  
    "control_smoothness": 0.2,   # 20% weight
    "path_accuracy": 0.2         # 20% weight
}

func update_trail_quality():
    # Calculate each factor
    var alignment_score = calculate_alignment_score()
    var velocity_score = calculate_velocity_matching_score()
    var smoothness_score = calculate_control_smoothness()
    var path_score = calculate_path_accuracy()
    
    # Weighted average
    trail_quality = (
        alignment_score * trail_quality_factors.alignment_error +
        velocity_score * trail_quality_factors.velocity_matching +
        smoothness_score * trail_quality_factors.control_smoothness +
        path_score * trail_quality_factors.path_accuracy
    )
    
    # Update trail color
    update_trail_color()

func update_trail_color():
    var color: Color
    if trail_quality > 0.9:
        color = Color.GREEN
    elif trail_quality > 0.7:
        color = Color.YELLOW
    elif trail_quality > 0.5:
        color = Color.ORANGE
    else:
        color = Color.RED
    
    if trail_line:
        trail_line.default_color = color
```

**What NOT to do**: 
- Don't request trajectory updates
- Don't communicate with BatchMPCManager
- Don't make waypoint decisions

### **StandardTorpedo.gd** (extends TorpedoBase)
**Why**: Even simple torpedoes benefit from waypoint visualization and velocity planning

Simple direct-attack torpedo with velocity awareness:
```gdscript
func generate_initial_waypoints():
    # Called once at launch - BatchMPCManager will update later
    var to_target = target.global_position - global_position
    var distance = to_target.length()
    var distance_meters = distance * WorldSettings.meters_per_pixel
    
    waypoints.clear()
    
    # Calculate if we'll need velocity management
    var final_velocity_if_constant_accel = sqrt(2 * max_acceleration * distance_meters)
    var needs_velocity_management = final_velocity_if_constant_accel > 10000.0  # 10 km/s threshold
    
    if needs_velocity_management:
        generate_velocity_managed_waypoints(distance, to_target)
    else:
        generate_simple_waypoints(distance, to_target)
```

### **SmartTorpedo.gd** (extends TorpedoBase)
**Why**: Complex trajectories REQUIRE velocity management and flip-burn capabilities

Advanced multi-role torpedo that receives trajectory updates from BatchMPCManager:

```gdscript
extends TorpedoBase

# Flight plan set at launch
var flight_plan_type: String = "straight"
var flight_plan_data: Dictionary = {}

func _ready():
    # Parent handles physics setup
    super._ready()
    
    # Generate initial waypoints based on flight plan
    match flight_plan_type:
        "straight":
            generate_initial_straight_waypoints()
        "multi_angle":
            generate_initial_multi_angle_waypoints()
        "simultaneous":
            generate_initial_simultaneous_waypoints()
    
    # BatchMPCManager will update our waypoints via pull system

# Called by BatchMPCManager when new waypoints arrive
func apply_waypoint_update(new_waypoints: Array, protected_count: int):
    # Preserve current and next N waypoints
    var preserved = []
    for i in range(min(protected_count, waypoints.size())):
        preserved.append(waypoints[current_waypoint_index + i])
    
    # Clear old waypoints
    waypoints.clear()
    
    # Add preserved waypoints first
    waypoints.append_array(preserved)
    
    # Add new waypoints
    for wp in new_waypoints:
        if waypoints.size() < preserved.size() or wp != waypoints[-1]:
            waypoints.append(wp)
```

### **BatchMPCManager.gd** (Singleton)
**Why**: Centralized pull-based scheduling eliminates update stampedes and ensures efficient GPU usage

Manages the pull-based update cycle:

```gdscript
extends Node
class_name BatchMPCManager

# Update scheduling
var update_timer: float = 0.0
var base_update_interval: float = 1.0  # 1 Hz baseline
var current_update_interval: float = 1.0

# System references  
var trajectory_planner: TrajectoryPlanner

# Batch state
var current_batch_size: int = 0
var last_update_time: float = 0.0

# Signals for event-based architecture
signal waypoints_updated(torpedo_id: String, waypoints: Array)
signal batch_update_started()
signal batch_update_completed(torpedo_count: int)

# Time dilation support
var use_real_time_updates: bool = true  # For tuning mode

func _ready():
    trajectory_planner = get_node("/root/TrajectoryPlanner")
    set_process(true)

func _process(delta):
    # Use real-world time for updates during time dilation
    var effective_delta = delta
    if use_real_time_updates and Engine.time_scale != 1.0:
        effective_delta = delta / Engine.time_scale
    
    update_timer += effective_delta
    
    if update_timer >= current_update_interval:
        update_timer = 0.0
        execute_batch_update()

func execute_batch_update():
    emit_signal("batch_update_started")
    var start_time = Time.get_ticks_usec()
    
    # Collect all valid torpedo states (with zero-trust validation)
    var torpedo_states = collect_and_validate_torpedo_states()
    
    if torpedo_states.is_empty():
        emit_signal("batch_update_completed", 0)
        return
    
    current_batch_size = torpedo_states.size()
    
    # Calculate dynamic update rate based on closest time-to-impact
    var min_time_to_impact = calculate_minimum_time_to_impact(torpedo_states)
    current_update_interval = calculate_update_interval(min_time_to_impact)
    
    # Send batch to GPU via TrajectoryPlanner
    var gpu_results = trajectory_planner.generate_waypoints_batch(torpedo_states)
    
    # Apply results to torpedoes
    apply_batch_results(gpu_results, torpedo_states)
    
    # Performance tracking
    var batch_time = (Time.get_ticks_usec() - start_time) / 1000.0
    last_update_time = batch_time
    
    emit_signal("batch_update_completed", current_batch_size)

func collect_and_validate_torpedo_states() -> Array:
    var valid_states = []
    var torpedoes = get_tree().get_nodes_in_group("torpedoes")
    
    for torpedo in torpedoes:
        # Zero-trust validation
        if not is_instance_valid(torpedo):
            continue
        if not torpedo.is_inside_tree():
            continue
        if torpedo.get("marked_for_death"):
            continue
            
        # Validate physics state
        var pos = torpedo.global_position
        var vel = torpedo.get("velocity_mps")
        if not vel or vel.length() > 1000000:  # Sanity check
            continue
            
        # Package state for GPU
        var state = {
            "torpedo_ref": torpedo,
            "torpedo_id": torpedo.get("torpedo_id"),
            "position": pos,
            "velocity": vel,
            "orientation": torpedo.get("orientation"),
            "max_acceleration": torpedo.get("max_acceleration"),
            "max_rotation_rate": torpedo.get("max_rotation_rate"),
            "target_position": get_target_position(torpedo),
            "target_velocity": get_target_velocity(torpedo),
            "flight_plan_type": torpedo.get("flight_plan_type"),
            "flight_plan_data": torpedo.get("flight_plan_data")
        }
        
        valid_states.append(state)
    
    return valid_states

func calculate_update_interval(time_to_impact: float) -> float:
    # Dynamic update rate: 1-3 Hz based on urgency
    if time_to_impact >= 15.0:
        return 1.0  # 1 Hz for distant targets
    elif time_to_impact >= 10.0:
        return 0.5  # 2 Hz for medium range
    elif time_to_impact >= 5.0:
        return 0.33  # 3 Hz for close range
    else:
        return 0.33  # Cap at 3 Hz even in terminal phase

func apply_batch_results(gpu_results: Array, torpedo_states: Array):
    # Protected waypoint count (current + next 2)
    var protected_count = 3
    
    for i in range(min(gpu_results.size(), torpedo_states.size())):
        var result = gpu_results[i]
        var state = torpedo_states[i]
        var torpedo = state.torpedo_ref
        
        if not is_instance_valid(torpedo):
            continue
            
        # Apply waypoint update to torpedo
        if torpedo.has_method("apply_waypoint_update"):
            torpedo.apply_waypoint_update(result.waypoints, protected_count)
            
            # Emit signal for visualization
            emit_signal("waypoints_updated", state.torpedo_id, result.waypoints)
```

### **TrajectoryPlanner.gd** (Singleton)
**Why**: GPU acceleration makes complex trajectory optimization with full physics validation feasible

GPU-only trajectory generation with zero CPU fallback:

```gdscript
extends Node
class_name TrajectoryPlanner

# GPU compute resources
var rd: RenderingDevice
var shader: RID
var pipeline: RID

# Error handling
var gpu_available: bool = false
var initialization_error: String = ""

# Physics validation parameters
const TURN_RADIUS_SAFETY_FACTOR: float = 1.5  # 50% safety margin
const MIN_WAYPOINT_SPACING_METERS: float = 100.0
const FLIP_DURATION_SECONDS: float = 2.5
const VELOCITY_CHANGE_RATE_LIMIT: float = 2000.0  # m/s per second max

# Tuning parameters loaded from ManualTuningParameters singleton
var trajectory_params: Dictionary = {}

# Waypoint density control
var waypoint_density_threshold: float = 0.2  # From manual tuning

func _ready():
    initialize_gpu_compute()
    
    if not gpu_available:
        push_error("GPU Compute Required - This game requires GPU compute shaders")
        get_tree().quit()

func initialize_gpu_compute():
    # Create rendering device
    rd = RenderingServer.create_local_rendering_device()
    
    if not rd:
        initialization_error = "Failed to create rendering device - GPU compute not supported"
        return
    
    # Load and compile shader
    var shader_file = load("res://Shaders/trajectory_planning_v9.glsl")
    if not shader_file:
        initialization_error = "Failed to load trajectory planning shader"
        return
        
    var shader_spirv = shader_file.get_spirv()
    shader = rd.shader_create_from_spirv(shader_spirv)
    
    if not shader or shader == RID():
        initialization_error = "Failed to create shader from SPIR-V"
        return
        
    # Create compute pipeline
    pipeline = rd.compute_pipeline_create(shader)
    
    if not pipeline or pipeline == RID():
        initialization_error = "Failed to create compute pipeline"
        return
    
    gpu_available = true
    print("TrajectoryPlanner: GPU compute initialized successfully")

func generate_waypoints_batch(torpedo_states: Array) -> Array:
    if not gpu_available:
        push_error("TrajectoryPlanner: GPU not available!")
        return []
    
    var start_time = Time.get_ticks_usec()
    
    # Get tuned parameters from singleton
    var params = ManualTuningParameters.get_current_parameters()
    
    # Prepare GPU buffers
    var gpu_input = prepare_gpu_input(torpedo_states, params)
    var gpu_output = execute_gpu_computation(gpu_input)
    
    # Process results
    var results = []
    for i in range(torpedo_states.size()):
        var waypoints = extract_waypoints_for_torpedo(gpu_output, i)
        waypoints = apply_adaptive_waypoint_density(waypoints, params.waypoint_density_threshold)
        
        # Validate physics
        if not validate_trajectory_physics(waypoints):
            # If invalid, generate emergency straight-line waypoints
            waypoints = generate_emergency_waypoints(torpedo_states[i])
        
        results.append({
            "torpedo_id": torpedo_states[i].torpedo_id,
            "waypoints": waypoints
        })
    
    var compute_time = (Time.get_ticks_usec() - start_time) / 1000.0
    if compute_time > 10.0:
        print("TrajectoryPlanner: Slow computation - %.1f ms for %d torpedoes" % [compute_time, torpedo_states.size()])
    
    return results

func apply_adaptive_waypoint_density(waypoints: Array, threshold: float) -> Array:
    """Subdivide waypoints based on velocity changes"""
    if waypoints.size() < 2:
        return waypoints
    
    var densified = []
    densified.append(waypoints[0])
    
    for i in range(1, waypoints.size()):
        var wp1 = waypoints[i-1]
        var wp2 = waypoints[i]
        
        # Check velocity change
        var vel_change = abs(wp2.velocity_target - wp1.velocity_target) / max(wp1.velocity_target, 100.0)
        var needs_subdivision = vel_change > threshold
        
        # Also check direction change
        if wp1.velocity_target > 100 and wp2.velocity_target > 100:
            var dir1 = calculate_velocity_direction(wp1)
            var dir2 = calculate_velocity_direction(wp2)
            var angle_change = abs(dir1.angle_to(dir2))
            if angle_change > deg_to_rad(30):
                needs_subdivision = true
        
        if needs_subdivision:
            # Add intermediate waypoints
            var subdivisions = ceil(vel_change / threshold)
            subdivisions = min(subdivisions, 5)  # Cap at 5
            
            for j in range(1, subdivisions):
                var t = float(j) / subdivisions
                var mid_waypoint = interpolate_waypoints(wp1, wp2, t)
                densified.append(mid_waypoint)
        
        densified.append(wp2)
    
    # Ensure we don't exceed max waypoints
    var max_waypoints = ManualTuningParameters.get_parameter("max_waypoints", 100)
    if densified.size() > max_waypoints:
        densified = reduce_waypoint_count(densified, max_waypoints)
    
    return densified

func validate_trajectory_physics(waypoints: Array) -> bool:
    """Validate that trajectory is physically achievable"""
    
    if waypoints.size() < 2:
        return false
    
    var validation_passed = true
    
    for i in range(waypoints.size() - 1):
        var wp1 = waypoints[i]
        var wp2 = waypoints[i + 1]
        
        # Check waypoint spacing
        var distance = wp1.position.distance_to(wp2.position) * WorldSettings.meters_per_pixel
        if distance < MIN_WAYPOINT_SPACING_METERS:
            validation_passed = false
            continue
        
        # Check velocity change feasibility
        var time_between = estimate_time_between_waypoints(wp1, wp2)
        var velocity_change = abs(wp2.velocity_target - wp1.velocity_target)
        var max_velocity_change = wp1.max_acceleration * time_between
        
        if velocity_change > max_velocity_change * 1.1:  # 10% tolerance
            validation_passed = false
        
        # Check turn radius if direction changes significantly
        if i > 0:
            var wp0 = waypoints[i - 1]
            var dir1 = (wp1.position - wp0.position).normalized()
            var dir2 = (wp2.position - wp1.position).normalized()
            var angle_change = acos(clamp(dir1.dot(dir2), -1.0, 1.0))
            
            if angle_change > deg_to_rad(5):  # Significant turn
                var velocity = wp1.velocity_target
                var required_radius = distance / (2 * sin(angle_change / 2))
                var actual_radius = (velocity * velocity) / wp1.max_acceleration
                
                if actual_radius > required_radius * TURN_RADIUS_SAFETY_FACTOR:
                    validation_passed = false
    
    return validation_passed
```

### **ProportionalNavigation.gd** (Component)
**Why**: PN naturally creates smooth curves through waypoints, now with velocity matching

Layer 2 guidance for precise waypoint following:

```gdscript
class_name ProportionalNavigation
extends Node

# Core parameters from ManualTuningParameters
var navigation_constant_N: float = 3.0
var velocity_gain: float = 0.001
var velocity_anticipation: float = 0.5
var rotation_thrust_penalty: float = 0.5
var thrust_smoothing: float = 0.5
var position_tolerance: float = 100.0
var velocity_tolerance: float = 500.0

# PN state
var last_los_angle: float = 0.0
var first_frame: bool = true
var last_thrust: float = 0.5
var thrust_ramp_start_time: float = 0.0

func _ready():
    # Load parameters from tuning singleton
    update_parameters_from_tuning()
    
    # Listen for parameter changes during tuning
    if ManualTuningParameters.has_signal("parameters_changed"):
        ManualTuningParameters.parameters_changed.connect(update_parameters_from_tuning)

func update_parameters_from_tuning():
    var params = ManualTuningParameters.get_layer2_parameters()
    navigation_constant_N = params.get("navigation_constant_N", navigation_constant_N)
    velocity_gain = params.get("velocity_gain", velocity_gain)
    velocity_anticipation = params.get("velocity_anticipation", velocity_anticipation)
    rotation_thrust_penalty = params.get("rotation_thrust_penalty", rotation_thrust_penalty)
    thrust_smoothing = params.get("thrust_smoothing", thrust_smoothing)
    position_tolerance = params.get("position_tolerance", position_tolerance)
    velocity_tolerance = params.get("velocity_tolerance", velocity_tolerance)

func calculate_guidance(torpedo_pos: Vector2, torpedo_vel: Vector2, 
                       torpedo_orientation: float, torpedo_max_acceleration: float,
                       torpedo_max_rotation: float,
                       current_waypoint: Waypoint,
                       next_waypoint: Waypoint = null) -> Dictionary:
    
    # Line of sight to current waypoint
    var los = current_waypoint.position - torpedo_pos
    var los_angle = los.angle()
    
    # First frame initialization
    if first_frame:
        last_los_angle = los_angle
        first_frame = false
        return {"turn_rate": 0.0, "thrust": 0.5}
    
    # Calculate LOS rate
    var los_rate = angle_difference(los_angle, last_los_angle) / get_physics_process_delta_time()
    last_los_angle = los_angle
    
    # Closing velocity
    var closing_velocity = -torpedo_vel.dot(los.normalized())
    
    # PN guidance law for position tracking
    var commanded_acceleration = navigation_constant_N * closing_velocity * los_rate
    var pn_turn_rate = commanded_acceleration / torpedo_vel.length() if torpedo_vel.length() > 0.1 else 0.0
    
    # Handle special maneuvers
    if current_waypoint.maneuver_type == "flip":
        # Flip maneuver - maximum rotation, no thrust
        return {
            "turn_rate": sign(angle_difference(torpedo_orientation + PI, torpedo_orientation)) * torpedo_max_rotation,
            "thrust": 0.0
        }
    
    # Velocity matching through thrust control
    var current_speed = torpedo_vel.length()
    var target_speed = current_waypoint.velocity_target
    var speed_error = target_speed - current_speed
    
    # Look ahead to next waypoint for anticipatory control
    if next_waypoint and velocity_anticipation > 0:
        var time_to_waypoint = los.length() / max(closing_velocity, 100.0)
        var next_speed = next_waypoint.velocity_target
        var speed_change_needed = next_speed - target_speed
        
        # Anticipate needed velocity changes
        if abs(speed_change_needed) > 1000.0 and time_to_waypoint < 5.0:
            var anticipation_factor = (1.0 - time_to_waypoint / 5.0) * velocity_anticipation
            target_speed = lerp(target_speed, next_speed, anticipation_factor)
            speed_error = target_speed - current_speed
    
    # Calculate thrust based on velocity error and maneuver type
    var thrust = calculate_thrust_for_velocity(
        speed_error, 
        current_waypoint.maneuver_type,
        current_waypoint.thrust_limit,
        torpedo_max_acceleration
    )
    
    # Apply rotation thrust penalty
    var rotation_factor = 1.0 - min(abs(pn_turn_rate) / torpedo_max_rotation, rotation_thrust_penalty)
    thrust *= rotation_factor
    
    # Apply thrust smoothing
    thrust = smooth_thrust_change(thrust)
    
    return {
        "turn_rate": clamp(pn_turn_rate, -torpedo_max_rotation, torpedo_max_rotation),
        "thrust": clamp(thrust, 0.2, 1.0)
    }
```

### **TorpedoVisualizer.gd** (Scene-wide Overlay)
**Why**: Visual debugging shows both trajectory planning and velocity management quality

Event-based visualization system:

```gdscript
extends Node2D
class_name TorpedoVisualizer

# Visual elements pools
var waypoint_pool: Array = []
var velocity_indicator_pool: Array = []
var trail_lines: Dictionary = {}  # torpedo_id -> Line2D

# Visual settings
var waypoint_colors = {
    "cruise": Color.WHITE,
    "boost": Color.GREEN,
    "flip": Color.YELLOW,
    "burn": Color.RED,
    "curve": Color(0.5, 0.5, 1.0),
    "terminal": Color.MAGENTA
}

func _ready():
    # Create object pools
    for i in range(1000):  # Support many waypoints
        var marker = ColorRect.new()
        marker.size = Vector2(16, 16)
        marker.visible = false
        waypoint_pool.append(marker)
        add_child(marker)
    
    # Listen to BatchMPCManager events
    var batch_manager = get_node("/root/BatchMPCManager")
    batch_manager.waypoints_updated.connect(_on_waypoints_updated)
    batch_manager.batch_update_started.connect(_on_batch_started)

func _on_waypoints_updated(torpedo_id: String, waypoints: Array):
    # Find torpedo
    var torpedo = find_torpedo_by_id(torpedo_id)
    if not torpedo:
        return
    
    # Update waypoint markers
    update_waypoint_markers(torpedo, waypoints)
    
    # Flash waypoints to indicate update
    flash_waypoints(torpedo_id)

func _on_batch_started():
    # Could show a subtle indicator that update is happening
    pass

func _process(_delta):
    # Update trails based on torpedo positions
    var torpedoes = get_tree().get_nodes_in_group("torpedoes")
    
    for torpedo in torpedoes:
        if not is_instance_valid(torpedo):
            continue
            
        var torpedo_id = torpedo.get("torpedo_id")
        if not torpedo_id:
            continue
        
        # Update trail
        if not trail_lines.has(torpedo_id):
            create_trail_for_torpedo(torpedo_id)
        
        var trail = trail_lines[torpedo_id]
        if trail and is_instance_valid(trail):
            trail.add_point(torpedo.global_position)
            
            # Limit trail length
            if trail.get_point_count() > 500:
                trail.remove_point(0)
            
            # Update trail color based on torpedo's quality score
            if torpedo.has_method("get_trail_quality"):
                var quality = torpedo.get_trail_quality()
                trail.default_color = get_quality_color(quality)

func get_quality_color(quality: float) -> Color:
    if quality > 0.9:
        return Color.GREEN
    elif quality > 0.7:
        return Color.YELLOW
    elif quality > 0.5:
        return Color.ORANGE
    else:
        return Color.RED

func flash_waypoints(torpedo_id: String):
    # Brief white flash to show update
    # Implementation depends on your visual style
    pass
```

### **ManualTuningParameters.gd** (Autoload Singleton)
**Why**: Central location for all tuning parameters accessible by all systems

```gdscript
extends Node

# Layer 1 Parameters (Trajectory Shaping)
var layer1_params = {
    "universal": {
        "waypoint_density_threshold": 0.2,
        "max_waypoints": 100
    },
    "straight": {
        "lateral_separation": 0.1,
        "convergence_delay": 0.8,
        "initial_boost_duration": 0.15
    },
    "multi_angle": {
        "flip_burn_threshold": 1.2,
        "deceleration_target": 2000.0,
        "arc_distance": 0.3,
        "arc_start": 0.1,
        "arc_peak": 0.5,
        "final_approach": 0.8
    },
    "simultaneous": {
        "flip_burn_threshold": 1.5,
        "deceleration_target": 3000.0,
        "fan_out_rate": 1.0,
        "fan_duration": 0.25,
        "converge_start": 0.7,
        "converge_aggression": 1.0
    }
}

# Layer 2 Parameters (Execution Control)
var layer2_params = {
    "navigation_constant_N": 3.0,
    "velocity_gain": 0.001,
    "velocity_anticipation": 0.5,
    "rotation_thrust_penalty": 0.5,
    "thrust_smoothing": 0.5,
    "position_tolerance": 100.0,
    "velocity_tolerance": 500.0
}

signal parameters_changed(layer: int, param_name: String, value: float)

func get_parameter(path: String, default = null):
    # Handle nested parameters like "multi_angle.arc_distance"
    var parts = path.split(".")
    var current = layer1_params
    
    for i in range(parts.size() - 1):
        if parts[i] in current:
            current = current[parts[i]]
        else:
            return default
    
    return current.get(parts[-1], default)

func set_parameter(layer: int, param_name: String, value: float):
    if layer == 1:
        # Handle nested structure for layer 1
        # Implementation depends on UI structure
        pass
    else:
        layer2_params[param_name] = value
    
    emit_signal("parameters_changed", layer, param_name, value)

func get_layer2_parameters() -> Dictionary:
    return layer2_params.duplicate()

func get_current_parameters() -> Dictionary:
    # Return all parameters for TrajectoryPlanner
    return {
        "layer1": layer1_params.duplicate(true),
        "layer2": layer2_params.duplicate()
    }
```

## Tuning System v9 - Time Dilation with Real-Time Feedback

### Overview
A manual tuning system with time dilation control, where Layer 1 shapes trajectories and Layer 2 controls execution quality. All parameters are adjusted through manual sliders with real-time visual feedback.

### Core Features
- **Time Dilation Control**: 0.1x to 4.0x game speed
- **Real-Time Updates**: Waypoints update at 1-3Hz real-world time regardless of game speed
- **Visual Feedback**: Colored sliders and torpedo trails indicate performance
- **No Preview Mode**: Everything runs normally, just slower/faster

### Time Dilation Implementation

```gdscript
# In ManualTuningPanel.gd
@onready var time_scale_slider: HSlider = $TimeScaleSlider
@onready var time_scale_label: Label = $TimeScaleLabel

func _ready():
    time_scale_slider.min_value = -2.0  # 0.1x speed
    time_scale_slider.max_value = 2.0   # 4.0x speed
    time_scale_slider.value = 0.0      # 1.0x speed
    time_scale_slider.value_changed.connect(_on_time_scale_changed)

func _on_time_scale_changed(value: float):
    # Exponential scale for intuitive control
    var time_scale = pow(2.0, value)
    Engine.time_scale = time_scale
    
    # Update label
    if time_scale < 1.0:
        time_scale_label.text = "Speed: %.1fx (Slow)" % time_scale
    elif time_scale > 1.0:
        time_scale_label.text = "Speed: %.1fx (Fast)" % time_scale
    else:
        time_scale_label.text = "Speed: 1.0x (Normal)"
    
    # Notify BatchMPCManager to use real-time updates
    var batch_manager = get_node("/root/BatchMPCManager")
    batch_manager.use_real_time_updates = true
```

### Layer 1 - Trajectory Shaping (Manual)

Layer 1 parameters control the overall shape and strategy of the torpedo's path.

#### Parameter Sliders with Performance Indicators

```gdscript
# In ManualTuningPanel.gd
class SliderControl:
    var slider: HSlider
    var label: Label
    var background: ColorRect
    var param_name: String
    var performance_score: float = 1.0
    
    func update_performance_color():
        var color: Color
        if performance_score > 0.95:
            color = Color.GREEN
        elif performance_score > 0.85:
            color = Color.YELLOW
        elif performance_score > 0.70:
            color = Color.ORANGE
        else:
            color = Color.RED
        
        background.color = color.darkened(0.7)
```

### Layer 2 - Execution Control (Manual)

Layer 2 parameters are monitored in real-time with colored feedback:

```gdscript
func update_layer2_feedback():
    # Get current performance metrics from torpedoes
    var metrics = collect_torpedo_metrics()
    
    # Update slider colors based on performance
    for param_name in layer2_sliders:
        var slider_control = layer2_sliders[param_name]
        
        match param_name:
            "navigation_constant_N":
                slider_control.performance_score = 1.0 - metrics.avg_position_error / 1000.0
            "velocity_gain":
                slider_control.performance_score = 1.0 - metrics.avg_velocity_error / 5000.0
            "velocity_anticipation":
                slider_control.performance_score = metrics.anticipation_quality
            "rotation_thrust_penalty":
                slider_control.performance_score = metrics.rotation_efficiency
            "thrust_smoothing":
                slider_control.performance_score = metrics.control_smoothness
        
        slider_control.update_performance_color()

func collect_torpedo_metrics() -> Dictionary:
    var metrics = {
        "avg_position_error": 0.0,
        "avg_velocity_error": 0.0,
        "anticipation_quality": 0.0,
        "rotation_efficiency": 0.0,
        "control_smoothness": 0.0
    }
    
    var torpedoes = get_tree().get_nodes_in_group("torpedoes")
    var valid_count = 0
    
    for torpedo in torpedoes:
        if not is_instance_valid(torpedo) or torpedo.get("marked_for_death"):
            continue
            
        # Collect metrics from each torpedo
        if torpedo.has_method("get_performance_metrics"):
            var t_metrics = torpedo.get_performance_metrics()
            metrics.avg_position_error += t_metrics.position_error
            metrics.avg_velocity_error += t_metrics.velocity_error
            metrics.anticipation_quality += t_metrics.anticipation_score
            metrics.rotation_efficiency += t_metrics.rotation_efficiency
            metrics.control_smoothness += t_metrics.smoothness
            valid_count += 1
    
    # Average the metrics
    if valid_count > 0:
        for key in metrics:
            metrics[key] /= valid_count
    
    return metrics
```

### End-of-Cycle Statistics

When a tuning cycle completes (all torpedoes reach targets or timeout):

```gdscript
func print_cycle_statistics():
    print("\n=== TUNING CYCLE RESULTS ===")
    print("Trajectory Type: %s" % current_trajectory_type)
    print("Hit Rate: %d/%d (%.1f%%)" % [hits, total_fired, hit_percentage])
    print("\nAccuracy Metrics:")
    print("  Avg Impact Angle Error: %.1f°" % avg_angle_error)
    print("  Avg Velocity Match Error: %.1f m/s" % avg_velocity_error)
    print("  Avg Impact Distance: %.1f m" % avg_impact_distance)
    
    if current_trajectory_type == "simultaneous":
        print("\nSimultaneous Impact Metrics:")
        print("  Time Spread: %.2f seconds" % time_spread)
        print("  Angle Coverage: %.1f°" % angle_coverage)
    
    print("\nControl Quality:")
    print("  Avg Smoothness Score: %.2f" % avg_smoothness)
    print("  Avg Alignment Quality: %.2f" % avg_alignment)
    print("  Total Control Effort: %.1f" % total_control_effort)
    
    print("\nGPU Performance:")
    print("  Avg Update Time: %.1f ms" % avg_gpu_time)
    print("  Peak Update Time: %.1f ms" % peak_gpu_time)
    print("================================\n")
```

# V9 MPC Implementation Guide

## Prerequisites
- GPU compute support is mandatory - no CPU fallback
- Back up your entire project before starting
- Ensure Godot 4.x with Vulkan renderer
- Have V9 plan document available for reference

## Step 1: File Cleanup and Test Removal

**1.1 Delete test files:**
```
- Scripts/Systems/TestComputeShader.gd
- Shaders/test_compute.glsl
- Shaders/test_compute_shader.glsl
- Shaders/test_compute.glsl.import
- Shaders/test_compute_shader.glsl.import
```

**1.2 Remove test references:**
- Open WorldRoot.tscn
- Delete GPUTest node
- Remove any autoload references to test scripts

**1.3 Delete obsolete MPC files:**
```
- Scripts/Systems/BatchMPCManager.gd (old version)
- Scripts/Systems/GPUBatchCompute.gd
- Scripts/Systems/MPCController.gd
- Scripts/Systems/MPCTuner.gd
- Scripts/Systems/MPCTuningObserver.gd
- Shaders/mpc_trajectory_batch.glsl
- Shaders/mpc_trajectory_batch.glsl.import
```

**1.4 Verify deletion:**
- Search project for any remaining references to deleted files
- Check that no scripts have imports of deleted classes

## Step 2: Create Core Architecture

**2.1 Create ManualTuningParameters singleton:**
- Location: `Scripts/Systems/ManualTuningParameters.gd`
- Copy implementation from V9 plan lines 1098-1195
- Add to Project Settings → Autoload:
  - Name: ManualTuningParameters
  - Path: res://Scripts/Systems/ManualTuningParameters.gd
  - Enable: ✓

**2.2 Create new BatchMPCManager (pull-based):**
- Location: `Scripts/Systems/BatchMPCManager.gd`
- Key implementation points:
  ```gdscript
  # Timer-based pulling (not torpedo-initiated)
  var update_timer: float = 0.0
  var update_interval: float = 0.016  # 60 FPS base
  
  # Pull-based cycle
  func execute_batch_update():
      var torpedo_states = collect_and_validate_torpedo_states()
      var gpu_results = trajectory_planner.generate_waypoints_batch(torpedo_states)
      apply_batch_results(gpu_results, torpedo_states)
  ```

**2.3 Create TrajectoryPlanner (GPU-only):**
- Location: `Scripts/Systems/TrajectoryPlanner.gd`
- Critical: NO CPU fallback code
- Initialize GPU in `_ready()`:
  ```gdscript
  func _ready():
      initialize_gpu_compute()
      if not gpu_available:
          push_error("GPU Compute Required - This game requires GPU compute shaders")
          get_tree().quit()
  ```

## Step 3: Create GPU Compute Shader

**3.1 Create trajectory planning shader:**
- Location: `Shaders/trajectory_planning_v9.glsl`
- Structure:
  ```glsl
  #[compute]
  #version 450
  
  layout(local_size_x = 64) in;
  
  // Waypoint generation with physics validation
  // Flip-burn detection and planning
  // Velocity profile generation
  ```

**3.2 Implement physics validation in shader:**
- Turn radius calculations
- Velocity feasibility checks
- Waypoint spacing validation

## Step 4: Refactor Torpedo System

**4.1 Rename and refactor TorpedoMPC.gd:**
```bash
1. Rename file: TorpedoMPC.gd → SmartTorpedo.gd
2. Update class_name to SmartTorpedo
3. Remove all direct MPC controller references
4. Add waypoint application method:
```
```gdscript
func apply_waypoint_update(new_waypoints: Array, protected_count: int):
    # Preserve current and next N waypoints
    # Apply new waypoints from GPU
```

**4.2 Update TorpedoMPC.tscn:**
- Change script reference to SmartTorpedo.gd
- Save as SmartTorpedo.tscn
- Update TorpedoLauncher prefab references

**4.3 Create/Update TorpedoBase.gd:**
- Add enhanced waypoint class with velocity profiles
- Add trail quality calculation
- Ensure NO direct BatchMPCManager calls

## Step 5: Create Layer 2 Guidance

**5.1 Create ProportionalNavigation.gd:**
- Location: `Scripts/Systems/ProportionalNavigation.gd`
- This is a NEW file - implement from V9 plan
- Key features:
  ```gdscript
  # Velocity matching
  var velocity_gain: float = 0.001
  var velocity_anticipation: float = 0.5
  
  # Special maneuver handling
  if current_waypoint.maneuver_type == "flip":
      return {"turn_rate": max_rotation, "thrust": 0.0}
  ```

**5.2 Connect to ManualTuningParameters:**
```gdscript
func _ready():
    ManualTuningParameters.parameters_changed.connect(update_parameters_from_tuning)
```

## Step 6: Implement Tuning UI

**6.1 Create ManualTuningPanel.gd:**
- Location: `Scripts/UI/ManualTuningPanel.gd`
- Time scale slider implementation:
  ```gdscript
  func _on_time_scale_changed(value: float):
      var time_scale = pow(2.0, value)  # Exponential scale
      Engine.time_scale = time_scale
      
      # Notify BatchMPCManager for real-time updates
      var batch_manager = get_node("/root/BatchMPCManager")
      batch_manager.use_real_time_updates = true
  ```

**6.2 Create Layer 1 sliders:**
- Waypoint density threshold
- Flip-burn threshold
- Deceleration target
- Arc parameters (for multi-angle)
- Fan parameters (for simultaneous)

**6.3 Create Layer 2 sliders with performance colors:**
- Navigation constant N
- Velocity gain
- Velocity anticipation
- Rotation thrust penalty
- Position/velocity tolerances

## Step 7: Update Event-Based Visualization

**7.1 Convert TorpedoVisualizer to events:**
```gdscript
func _ready():
    var batch_manager = get_node("/root/BatchMPCManager")
    batch_manager.waypoints_updated.connect(_on_waypoints_updated)
    batch_manager.batch_update_started.connect(_on_batch_started)
```

**7.2 Implement waypoint coloring by type:**
```gdscript
var waypoint_colors = {
    "cruise": Color.WHITE,
    "boost": Color.GREEN,
    "flip": Color.YELLOW,
    "burn": Color.RED,
    "curve": Color(0.5, 0.5, 1.0),
    "terminal": Color.MAGENTA
}
```

**7.3 Add trail quality visualization:**
- Color trails based on torpedo performance
- Green = excellent, Yellow = good, Orange = needs work, Red = poor

## Step 8: Update Game Mode Integration

**8.1 Update GameMode singleton:**
- Remove FPS locking for MPC tuning (now handled by time dilation)
- Ensure proper cleanup when switching modes

**8.2 Update ModeSelector:**
- Remove preview mode logic
- Ensure time dilation is properly initialized

## Step 9: Integration and Validation

**9.1 Verify singleton setup:**
- ManualTuningParameters in autoload
- BatchMPCManager in autoload
- TrajectoryPlanner in autoload

**9.2 Verify data flow:**
```
Timer (1-3Hz) → BatchMPCManager → TrajectoryPlanner → GPU
                        ↓
               Apply to Torpedoes ← Results
                        ↓
                ProportionalNavigation
```

**9.3 Test event connections:**
- Run with debug prints in event handlers
- Verify waypoint updates trigger visualization
- Check parameter changes update guidance

## Step 10: Performance Validation

**10.1 GPU performance checks:**
```gdscript
# In TrajectoryPlanner
if compute_time > 10.0:  # Log slow computations
    print("Trajectory planning took %.1f ms" % compute_time)
```

**10.2 Verify update rates:**
- 1Hz at >15s to impact
- 2Hz at 10-15s to impact
- 3Hz at <10s to impact

**10.3 Test time dilation:**
- 0.1x speed: Waypoints update at real-time rate
- 4.0x speed: Physics remain stable

## Troubleshooting Common Issues

**"GPU compute not available" error:**
- Verify Vulkan renderer in Project Settings
- Check GPU drivers are updated
- Ensure compute shader support in GPU

**Waypoints not updating:**
- Check BatchMPCManager timer is using real_delta during time dilation
- Verify event connections with debug prints
- Check zero-trust validation isn't rejecting valid torpedoes

**Circular dependency errors:**
- Torpedoes should NEVER call BatchMPCManager
- TrajectoryPlanner should NEVER access torpedoes directly
- All communication through events

**Time dilation not working:**
- Verify `use_real_time_updates` is set in BatchMPCManager
- Check `effective_delta = delta / Engine.time_scale`
- Ensure physics process uses standard delta

## Completion Checklist

After implementation, verify:
- [ ] All test files deleted
- [ ] No references to old MPC system
- [ ] GPU compute initializes successfully
- [ ] Pull-based updates working at correct rates
- [ ] Waypoints include velocity profiles
- [ ] ProportionalNavigation matches velocities
- [ ] Time dilation works (0.1x to 4.0x)
- [ ] Trail colors reflect quality
- [ ] Slider colors update in real-time
- [ ] No circular dependencies
- [ ] Events flow unidirectionally
- [ ] 60 FPS maintained with 8 torpedoes