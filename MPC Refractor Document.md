# MPC Torpedo System Refactoring Plan v8.0 - Complete Physics-First Implementation with Tuning System

## The Problem

The current MPC system is overcomplicated and fights against physics. Torpedoes oscillate between templates, can't hit stationary targets, and the "MPC" is really just template selection. The system tries to recalculate everything every frame instead of committing to a plan and following it smoothly. Templates are parameter sets, not actual trajectories, leading to jerky, unpredictable motion.

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

## The Solution

A true layered guidance system where GPU-based trajectory planning (Layer 1) generates physically-achievable waypoint paths with velocity profiles, and simple proportional navigation (Layer 2) smoothly flies through them matching both position and velocity targets. When physics demands it, we employ flip-and-burn maneuvers - the same technique The Expanse's ships use for navigation.

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

### What We DON'T Want
- Arbitrary speed caps (old 2000 m/s limit)
- Constant throttle cutting that wastes efficiency
- Impossible turns that physics won't allow
- Competing control objectives (alignment vs tracking)
- Different physics for different torpedo types
- Multiple flip-burns per approach (maximum 1, rarely 2)

## Core Data Architecture Principles

### Immediate State & Zero-Trust Design
**Why**: Godot's node system creates temporal coupling issues. Nodes can be freed between frames, references become invalid, and ID mismatches cause cascading failures. The time between storing a reference and using it is an eternity in game time - ships explode, torpedoes hit targets, PDCs intercept threats. By the time you use a stored reference, the entire battlefield may have changed.

### Fundamental Rules

1. **Never Store Node References**
   ```gdscript
   # WRONG - Reference might be invalid next frame
   var my_target: Node2D = torpedo_node
   
   # RIGHT - Store ID, validate every access
   var target_id: String = torpedo.torpedo_id
   func get_target() -> Node2D:
       return validate_and_get_torpedo(target_id)
   ```

2. **Every Frame is a Fresh Start**
   ```gdscript
   func _physics_process(delta):
       # Re-validate EVERYTHING
       if not is_instance_valid(current_waypoint_marker):
           current_waypoint_marker = null
       
       # Fresh queries for current state
       var valid_torpedoes = get_tree().get_nodes_in_group("torpedoes")
       for torpedo in valid_torpedoes:
           if is_valid_entity(torpedo):
               process_torpedo(torpedo)
   ```

3. **Self-Identifying Nodes**
   - Every torpedo carries its own complete identity
   - No external ID generation or mapping
   - Identity baked into the node as exported properties
   - Metadata redundancy for safety

4. **Mark for Death Pattern**
   ```gdscript
   func mark_for_destruction(reason: String):
       if marked_for_death:
           return  # Already dying
       
       marked_for_death = true
       is_alive = false
       
       # Immediate state changes
       set_physics_process(false)
       $CollisionShape2D.disabled = true
       
       # Notify then cleanup
       get_tree().call_group("battle_observers", "on_entity_dying", self, reason)
       queue_free()
   ```

### System-Specific Implications

**TrajectoryPlanner**:
- Don't store torpedo references between frames
- Each update request includes full torpedo state
- Waypoints returned as positions with velocity targets, not node references
- Validate torpedo still exists before applying updates

**ProportionalNavigation**:
- No stored reference to "current waypoint node"
- Calculate fresh each frame from waypoint array
- Match both position AND velocity targets from waypoints
- Validate torpedo exists before calculating guidance

**TorpedoVisualizer**:
- Trail nodes might be freed - check is_instance_valid()
- Waypoint markers are visual only - don't rely on them for logic
- Clear all visuals when torpedo dies, don't assume they'll clean themselves
- Show velocity targets and maneuver types visually

**SimpleAutoTuner**:
- Don't track torpedoes across cycles
- Count hits/misses through event observation, not direct tracking
- Ship reset positions are fresh teleports, not state preservation
- Tune for both position accuracy AND velocity matching

This architecture principle overrides any implementation detail that would violate it. When in doubt: query fresh, validate everything, trust nothing across frames.

## Files to DELETE

### Complete Removal
- `BatchMPCManager.gd` - replaced by TrajectoryPlanner
- `GPUBatchCompute.gd` - replaced by cleaner GPU planner
- `MPCController.gd` - no longer needed
- `MPCTuner.gd` - replaced by new manual tuning system
- `MPCTuningObserver.gd` - replaced by new preview mode
- `mpc_trajectory_batch.glsl` - replaced with trajectory planning shader

### Heavy Modification
- `TorpedoMPC.gd` - becomes SmartTorpedo.gd (90% rewrite)
- `ProportionalNavigation.gd` - add velocity matching (50% rewrite)
- `TrajectoryPlanner.gd` - add physics simulation (75% rewrite)

## New Architecture

### **TorpedoBase.gd**
**Why**: Shared foundation prevents code duplication and ensures consistent physics, launch behavior, and now velocity tracking

Provides ALL torpedoes with:
- Core physics state (position, velocity, orientation)
- Thrust and rotation application
- **Lateral launch system** (unchanged from v6.1)
- Trail rendering
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
            
        # NEW: Also accept if we're close in velocity and moving toward waypoint
        if vel_error < velocity_tolerance and is_moving_toward_waypoint(torpedo_pos, position):
            return true
            
        return false
```

Waypoint acceptance logic enhanced:
```gdscript
@export var acceptance_radius: float = 100.0  # meters
@export var waypoint_timeout: float = 10.0    # seconds per waypoint
@export var velocity_acceptance: float = 500.0 # m/s tolerance

func check_waypoint_advance():
    if current_waypoint_index >= waypoints.size() - 1:
        return  # Already at final waypoint
    
    var current_waypoint = waypoints[current_waypoint_index]
    var to_waypoint = current_waypoint.position - global_position
    var distance = to_waypoint.length()
    var distance_meters = distance * WorldSettings.meters_per_pixel
    
    # NEW: Check velocity matching
    var velocity_error = abs(velocity_mps.length() - current_waypoint.velocity_target)
    var velocity_matched = velocity_error < current_waypoint.velocity_tolerance
    
    # Three conditions for advancing (enhanced)
    if distance_meters < acceptance_radius:
        advance_waypoint("reached")
    elif to_waypoint.dot(velocity) < 0 and velocity_matched:
        advance_waypoint("passed_with_velocity_match")
    elif Time.get_ticks_msec() / 1000.0 - waypoint_start_time > waypoint_timeout:
        advance_waypoint("timeout")
        # Log velocity mismatch if that's why we timed out
        if not velocity_matched:
            print("Torpedo %s: Waypoint timeout with velocity error: %.1f m/s" % [torpedo_id, velocity_error])

func advance_waypoint(reason: String):
    # Store velocity achievement for tuning
    var wp = waypoints[current_waypoint_index]
    var velocity_achievement = 1.0 - (abs(velocity_mps.length() - wp.velocity_target) / wp.velocity_target)
    
    current_waypoint_index += 1
    waypoint_start_time = Time.get_ticks_msec() / 1000.0
    emit_signal("waypoint_reached", current_waypoint_index - 1, reason, velocity_achievement)
```

**What NOT to do**: 
- Don't put trajectory-specific logic here
- Don't add velocity control logic - that's Layer 2's job
- Don't make waypoint acceptance too strict on velocity

### **StandardTorpedo.gd** (extends TorpedoBase)
**Why**: Even simple torpedoes benefit from waypoint visualization and velocity planning

Simple direct-attack torpedo with velocity awareness:
```gdscript
func generate_waypoints():
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

func generate_simple_waypoints(distance: float, to_target: Vector2):
    # Initial offset to clear launching ship
    var offset_dir = Vector2.UP.rotated(launcher.rotation + launch_side * PI/2)
    waypoints.append(Waypoint.new(
        global_position + offset_dir * 100,
        500.0,  # Low initial velocity target
        "cruise",
        0.8
    ))
    
    # Acceleration phase waypoints
    for i in range(1, 4):
        var t = float(i) / 4.0
        waypoints.append(Waypoint.new(
            global_position + to_target * t,
            2000.0 + t * 8000.0,  # Ramping velocity
            "cruise",
            1.0
        ))
    
    # Terminal waypoint
    waypoints.append(Waypoint.new(
        target.global_position,
        10000.0,  # High impact velocity
        "terminal",
        1.0
    ))

func generate_velocity_managed_waypoints(distance: float, to_target: Vector2):
    # This is rare for straight torpedoes but handles extreme range
    # Plan a slight S-curve to manage velocity
    # ... implementation for velocity management
```

**What NOT to do**: 
- Don't make these use different physics or guidance laws
- Don't skip velocity planning even for "simple" torpedoes

### **SmartTorpedo.gd** (extends TorpedoBase)
**Why**: Complex trajectories REQUIRE velocity management and flip-burn capabilities

Advanced multi-role torpedo with physics-based planning:

**Multi-Angle Attack with Flip-Burn**:
```gdscript
func generate_multi_angle_waypoints():
    var to_target = target.global_position - global_position
    var distance = to_target.length()
    var distance_meters = distance * WorldSettings.meters_per_pixel
    var perpendicular = to_target.rotated(approach_side * PI/2).normalized()
    
    # Physics calculation - can we arc without flip-burn?
    var direct_velocity = calculate_direct_intercept_velocity(distance_meters)
    var turn_radius = (direct_velocity * direct_velocity) / max_acceleration
    var min_safe_radius = distance_meters * 0.15  # Need 15% of distance for safe arc
    
    waypoints.clear()
    
    if turn_radius > min_safe_radius:
        # MUST use flip-burn approach
        print("Torpedo %s: Turn radius %.1f km exceeds safe limit %.1f km - using flip-burn" % 
              [torpedo_id, turn_radius/1000.0, min_safe_radius/1000.0])
        generate_flip_burn_multi_angle()
    else:
        # Can use curved approach
        generate_curved_multi_angle()

func generate_flip_burn_multi_angle():
    # Phase 1: Aggressive positioning burn (30-40 waypoints)
    var burn_angle = PI/3 * approach_side  # 60° off direct path
    var burn_direction = to_target.rotated(burn_angle).normalized()
    
    # Calculate burn duration to reach position
    var lateral_displacement_needed = distance * 0.3  # Get 30% to the side
    var burn_time = calculate_burn_time_for_displacement(lateral_displacement_needed)
    var waypoints_for_burn = int(burn_time * 2)  # 2 waypoints per second
    
    for i in range(waypoints_for_burn):
        var t = float(i) / float(waypoints_for_burn - 1)
        var accel_profile = ease(t, 0.2)  # Smooth acceleration ramp
        
        waypoints.append(Waypoint.new(
            global_position + burn_direction * lateral_displacement_needed * accel_profile,
            1000.0 + 40000.0 * t,  # Accelerate to 41 km/s
            "cruise",
            0.9 + 0.1 * t  # Ramp thrust from 90% to 100%
        ))
    
    # Phase 2: Flip maneuver (3 waypoints)
    var flip_position = waypoints[-1].position
    var flip_velocity = waypoints[-1].velocity_target
    
    waypoints.append(Waypoint.new(
        flip_position + velocity.normalized() * 50,  # Pre-flip coast
        flip_velocity,
        "flip",
        0.0  # No thrust during flip
    ))
    
    waypoints.append(Waypoint.new(
        flip_position + velocity.normalized() * 150,  # Mid-flip
        flip_velocity,
        "flip",
        0.0
    ))
    
    waypoints.append(Waypoint.new(
        flip_position + velocity.normalized() * 250,  # Post-flip
        flip_velocity,
        "flip",
        0.0
    ))
    
    # Phase 3: Deceleration burn (20-30 waypoints)
    var decel_waypoints = 25
    var target_velocity = 2000.0  # Decelerate to 2 km/s for arc
    
    for i in range(decel_waypoints):
        var t = float(i) / float(decel_waypoints - 1)
        var vel = flip_velocity - (flip_velocity - target_velocity) * ease(t, 0.5)
        
        # Continue moving forward while decelerating
        var decel_pos = flip_position + burn_direction * (300 + i * 20)
        
        waypoints.append(Waypoint.new(
            decel_pos,
            vel,
            "burn",
            1.0  # Maximum thrust for deceleration
        ))
    
    # Phase 4: Arc approach at manageable velocity (40-50 waypoints)
    var arc_start_pos = waypoints[-1].position
    var arc_waypoints = 45
    
    for i in range(arc_waypoints):
        var t = float(i) / float(arc_waypoints - 1)
        
        # Calculate arc position
        var arc_progress = ease(t, 0.3)
        var to_target_from_arc = target.global_position - arc_start_pos
        
        # Blend from perpendicular to direct approach
        var blend_factor = 1.0 - pow(t, 2)  # Start perpendicular, end direct
        var arc_offset = perpendicular * distance * 0.4 * blend_factor
        var arc_pos = arc_start_pos + to_target_from_arc * arc_progress + arc_offset
        
        # Gradually increase velocity during approach
        var approach_velocity = target_velocity + t * 8000.0  # Accelerate to 10 km/s
        
        waypoints.append(Waypoint.new(
            arc_pos,
            approach_velocity,
            "curve",
            0.7 + 0.3 * t  # Increase thrust as we straighten out
        ))
    
    # Final approach waypoint
    waypoints.append(Waypoint.new(
        target.global_position,
        10000.0,  # Maximum impact velocity
        "terminal",
        1.0
    ))
```

**Simultaneous Impact with Velocity Coordination**:
```gdscript
func generate_simultaneous_waypoints(assigned_angle: float, impact_time: float):
    # Calculate required path length based on impact time
    var direct_distance = global_position.distance_to(target.global_position)
    var direct_distance_meters = direct_distance * WorldSettings.meters_per_pixel
    
    # Physics check - can we reach target in time?
    var min_flight_time = calculate_minimum_flight_time(direct_distance_meters)
    if impact_time < min_flight_time:
        print("WARNING: Impact time %.1fs less than minimum %.1fs" % [impact_time, min_flight_time])
        impact_time = min_flight_time * 1.1  # Add 10% margin
    
    waypoints.clear()
    
    # Fan angle determines how extreme our trajectory is
    var extreme_angle = abs(assigned_angle) > deg_to_rad(60)
    
    if extreme_angle:
        generate_extreme_simultaneous_trajectory(assigned_angle, impact_time)
    else:
        generate_moderate_simultaneous_trajectory(assigned_angle, impact_time)

func generate_extreme_simultaneous_trajectory(assigned_angle: float, impact_time: float):
    # For ±70-80° approaches, we NEED flip-burn
    
    # Phase 1: Fan out aggressively (20 waypoints)
    var fan_direction = Vector2.from_angle(parent_ship.rotation + assigned_angle)
    var fan_distance = 500.0  # kilometers
    
    for i in range(20):
        var t = float(i) / 19.0
        var fan_progress = ease(t, 0.2)
        
        waypoints.append(Waypoint.new(
            global_position + fan_direction * fan_distance * fan_progress,
            500.0 + 20000.0 * t,  # Accelerate to 20.5 km/s
            "cruise",
            1.0
        ))
    
    # Phase 2: Flip maneuver
    # Similar to multi-angle but timed for simultaneous arrival
    # ... (flip waypoints as before)
    
    # Phase 3: Deceleration to manageable speed
    # ... (deceleration waypoints)
    
    # Phase 4: Timed approach
    var remaining_time = impact_time - calculate_elapsed_time(waypoints)
    var remaining_distance = calculate_remaining_distance(waypoints[-1].position, target.global_position)
    var required_velocity = remaining_distance / remaining_time
    
    # Generate waypoints to match timing requirement
    # ... (timed approach waypoints)
```

**What NOT to do**: 
- Don't add special physics - complexity comes from waypoints
- Don't allow more than one flip-burn per trajectory
- Don't generate physically impossible velocity transitions

### **TrajectoryPlanner.gd** (Singleton)
**Why**: GPU acceleration makes complex trajectory optimization with physics validation feasible

GPU-accelerated trajectory optimization with full physics simulation:

```gdscript
extends Node
class_name TrajectoryPlanner

# GPU compute resources
var rd: RenderingDevice
var shader: RID
var pipeline: RID

# Physics validation parameters
const TURN_RADIUS_SAFETY_FACTOR: float = 1.5  # 50% safety margin
const MIN_WAYPOINT_SPACING_METERS: float = 100.0
const FLIP_DURATION_SECONDS: float = 2.5
const VELOCITY_CHANGE_RATE_LIMIT: float = 2000.0  # m/s per second max

# Tuning parameters loaded from UI
var trajectory_params: Dictionary = {}

# NEW: Waypoint density control
var waypoint_density_threshold: float = 0.2  # From manual tuning

func generate_waypoints_gpu(torpedo: SmartTorpedo) -> Array:
    var start_time = Time.get_ticks_usec()
    
    # Prepare state for GPU
    var current_state = torpedo.get_physics_state()
    var target_state = torpedo.get_target_state()
    var constraints = torpedo.get_trajectory_constraints()
    
    # Get tuned parameters from manual UI
    var params = get_tuned_parameters(torpedo.flight_plan_type)
    
    # Determine if flip-burn is required based on tuned threshold
    var needs_flip_burn = evaluate_flip_burn_requirement(
        current_state, target_state, constraints, params.flip_burn_threshold
    )
    
    if needs_flip_burn:
        # Generate flip-burn trajectory on CPU (too complex for current GPU shader)
        var trajectory = generate_flip_burn_trajectory_cpu(
            current_state, target_state, constraints, params
        )
        trajectory = apply_adaptive_waypoint_density(trajectory)
        validate_trajectory_physics(trajectory)
        return trajectory
    
    # Use GPU for standard trajectory optimization
    var gpu_result = compute_trajectory_gpu(current_state, target_state, constraints)
    gpu_result = apply_adaptive_waypoint_density(gpu_result)
    
    # Validate physics
    if not validate_trajectory_physics(gpu_result):
        # GPU trajectory is impossible - fall back to flip-burn
        print("GPU trajectory failed physics validation - using flip-burn")
        return generate_flip_burn_trajectory_cpu(
            current_state, target_state, constraints, params
        )
    
    var compute_time = (Time.get_ticks_usec() - start_time) / 1000.0
    if compute_time > 10.0:  # Log slow computations
        print("Trajectory planning took %.1f ms" % compute_time)
    
    return gpu_result

func apply_adaptive_waypoint_density(waypoints: Array) -> Array:
    """Subdivide waypoints based on velocity changes"""
    if waypoints.size() < 2:
        return waypoints
    
    var densified = []
    densified.append(waypoints[0])
    
    for i in range(1, waypoints.size()):
        var wp1 = waypoints[i-1]
        var wp2 = waypoints[i]
        
        # Check velocity change
        var vel_change = abs(wp2.velocity_target - wp1.velocity_target) / wp1.velocity_target
        var needs_subdivision = vel_change > waypoint_density_threshold
        
        # Also check direction change
        if wp1.velocity_target > 100 and wp2.velocity_target > 100:
            var dir1 = calculate_velocity_direction(wp1)
            var dir2 = calculate_velocity_direction(wp2)
            var angle_change = abs(dir1.angle_to(dir2))
            if angle_change > deg_to_rad(30):
                needs_subdivision = true
        
        if needs_subdivision:
            # Add intermediate waypoints
            var subdivisions = ceil(vel_change / waypoint_density_threshold)
            for j in range(1, subdivisions):
                var t = float(j) / subdivisions
                var mid_waypoint = interpolate_waypoints(wp1, wp2, t)
                densified.append(mid_waypoint)
        
        densified.append(wp2)
    
    return densified

func evaluate_flip_burn_requirement(current_state: Dictionary, target_state: Dictionary, 
                                   constraints: Dictionary, threshold_multiplier: float) -> bool:
    """Determine if physics requires flip-burn maneuver with tunable threshold"""
    
    var to_target = target_state.position - current_state.position
    var distance = to_target.length()
    
    # Calculate velocity if we accelerate all the way
    var final_velocity = sqrt(
        current_state.velocity.length_squared() + 
        2 * constraints.max_acceleration * distance
    )
    
    # Calculate turn radius at that velocity
    var turn_radius = (final_velocity * final_velocity) / constraints.max_acceleration
    
    # Apply threshold multiplier from tuning
    var effective_turn_radius = turn_radius / threshold_multiplier
    
    # Check against trajectory requirements
    match constraints.trajectory_type:
        "multi_angle":
            # Need to turn ~90 degrees
            var required_turn_distance = distance * 0.3  # 30% for safe arc
            return effective_turn_radius > required_turn_distance
            
        "simultaneous":
            # Check if assigned angle is extreme
            if abs(constraints.assigned_angle) > deg_to_rad(60):
                return effective_turn_radius > distance * 0.2
            return false
            
        _:
            # Straight trajectories rarely need flip-burn
            return false

func validate_trajectory_physics(waypoints: Array) -> bool:
    """Validate that trajectory is physically achievable"""
    
    if waypoints.size() < 2:
        return false
    
    var validation_passed = true
    var max_violation = 0.0
    
    for i in range(waypoints.size() - 1):
        var wp1 = waypoints[i]
        var wp2 = waypoints[i + 1]
        
        # Check waypoint spacing
        var distance = wp1.position.distance_to(wp2.position) * WorldSettings.meters_per_pixel
        if distance < MIN_WAYPOINT_SPACING_METERS:
            print("Waypoints too close: %.1f m" % distance)
            validation_passed = false
            continue
        
        # Check velocity change feasibility
        var time_between = estimate_time_between_waypoints(wp1, wp2)
        var velocity_change = abs(wp2.velocity_target - wp1.velocity_target)
        var max_velocity_change = wp1.max_acceleration * time_between
        
        if velocity_change > max_velocity_change * 1.1:  # 10% tolerance
            print("Velocity change impossible: need %.0f m/s in %.1f s (max: %.0f)" % 
                  [velocity_change, time_between, max_velocity_change])
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
                    var violation = actual_radius / required_radius
                    max_violation = max(max_violation, violation)
                    print("Turn radius violation at waypoint %d: %.1fx too large" % [i, violation])
                    validation_passed = false
    
    return validation_passed

func generate_flip_burn_trajectory_cpu(current_state: Dictionary, target_state: Dictionary, 
                                      constraints: Dictionary, params: Dictionary) -> Array:
    """Generate flip-burn trajectory when physics demands it"""
    
    var waypoints = []
    var to_target = target_state.position - current_state.position
    var distance = to_target.length()
    
    # Determine burn angle based on trajectory type and tuning
    var burn_angle = calculate_optimal_burn_angle(constraints, params)
    var burn_direction = to_target.rotated(burn_angle).normalized()
    
    # Phase 1: Acceleration burn
    var burn_time = 30.0  # seconds
    var burn_waypoints = int(burn_time * 2)  # 2 per second
    
    for i in range(burn_waypoints):
        var t = float(i) / float(burn_waypoints - 1)
        var acceleration = constraints.max_acceleration * (0.8 + 0.2 * t)  # Ramp up
        var burn_velocity = acceleration * t * burn_time
        
        waypoints.append(create_waypoint(
            current_state.position + burn_direction * calculate_burn_distance(t, burn_time, acceleration),
            min(burn_velocity, 50000.0),  # Cap at 50 km/s for safety
            "cruise",
            0.8 + 0.2 * t
        ))
    
    # Phase 2: Flip maneuver with tuned timing
    add_flip_waypoints(waypoints, burn_direction, constraints, params)
    
    # Phase 3: Deceleration burn to tuned target velocity
    var current_velocity = waypoints[-1].velocity_target
    var target_velocity = params.deceleration_target  # From manual tuning
    add_deceleration_waypoints(waypoints, current_velocity, target_velocity, constraints)
    
    # Phase 4: Final approach
    add_approach_waypoints(waypoints, target_state, constraints, params)
    
    return waypoints

func add_flip_waypoints(waypoints: Array, direction: Vector2, constraints: Dictionary, params: Dictionary):
    """Add flip maneuver waypoints with elegant timing"""
    var flip_position = waypoints[-1].position
    var flip_velocity = waypoints[-1].velocity_target
    
    # Pre-flip coast (0.4s)
    waypoints.append(create_waypoint(
        flip_position + direction * (flip_velocity * 0.4),
        flip_velocity,
        "flip",
        0.0
    ))
    
    # Mid-flip (0.5s rotation at 1080°/s = 540° = 1.5 rotations)
    waypoints.append(create_waypoint(
        flip_position + direction * (flip_velocity * 0.9),
        flip_velocity,
        "flip",
        0.0
    ))
    
    # Post-flip coast (0.4s)
    waypoints.append(create_waypoint(
        flip_position + direction * (flip_velocity * 1.3),
        flip_velocity,
        "flip",
        0.0
    ))
```

**Dynamic Update Rate** (unchanged from v6.1 but with velocity profile updates):
```gdscript
func calculate_update_rate(time_to_impact: float) -> float:
    if time_to_impact >= 15.0:
        return 1.0  # 1 Hz
    elif time_to_impact >= 10.0:
        return 2.0  # 2 Hz
    elif time_to_impact >= 5.0:
        return 3.0  # 3 Hz
    else:
        return 3.0  # Cap at 3 Hz even in terminal phase

func should_update_waypoints(torpedo: SmartTorpedo) -> bool:
    var time_to_impact = calculate_time_to_impact(torpedo)
    var update_rate = calculate_update_rate(time_to_impact)
    var time_since_last = Time.get_ticks_msec() / 1000.0 - torpedo.last_waypoint_update
    
    # Force update if physics violation detected
    if detect_physics_violation(torpedo):
        print("Physics violation detected - forcing trajectory update")
        return true
    
    return time_since_last >= (1.0 / update_rate)

func update_torpedo_waypoints(torpedo: SmartTorpedo):
    var new_waypoints = generate_waypoints_gpu(torpedo)
    
    # Protect current waypoint AND the next TWO after it
    var current_idx = torpedo.current_waypoint_index
    var protected_until = min(current_idx + 3, torpedo.waypoints.size())
    
    # Smooth velocity transitions in updated waypoints
    smooth_velocity_profile(new_waypoints, torpedo.velocity_mps.length(), protected_until)
    
    # Only update waypoints after the protection zone
    for i in range(protected_until, new_waypoints.size()):
        if i < torpedo.waypoints.size():
            torpedo.waypoints[i] = new_waypoints[i]
        else:
            torpedo.waypoints.append(new_waypoints[i])
    
    torpedo.last_waypoint_update = Time.get_ticks_msec() / 1000.0
```

**What NOT to do**: 
- Don't update waypoints torpedo is approaching or about to reach
- Don't generate physically impossible paths
- Don't allow arbitrary velocity changes between waypoints
- Don't skip physics validation to save computation time

### **trajectory_planning.glsl** (GPU Compute Shader)
**Why**: Parallel evaluation of trajectory variations with physics constraints

Enhanced GPU compute shader with velocity planning:
```glsl
#version 450

layout(local_size_x = 64) in;

// Torpedo state includes velocity targets now
struct WaypointData {
    vec2 position;
    float velocity_target;
    float maneuver_type;  // 0=cruise, 1=flip, 2=burn, 3=curve, 4=terminal
};

// Input buffers
layout(binding = 0) buffer TorpedoState {
    vec4 position_velocity;
    vec4 orientation_params;  // orientation, angular_vel, max_accel, max_rotation
} torpedo_state;

layout(binding = 1) buffer TargetState {
    vec4 position_velocity;
} target_state;

layout(binding = 2) buffer Constraints {
    vec4 params;  // trajectory_type, assigned_angle, impact_time, reserved
} constraints;

// Output buffer
layout(binding = 3) buffer TrajectoryOutput {
    WaypointData waypoints[100];
    float total_cost;
    float physics_valid;
} output;

// Shared memory for parallel physics validation
shared float physics_violations[64];

void main() {
    uint idx = gl_GlobalInvocationID.x;
    
    // Each thread evaluates a trajectory variant
    float variant_param = float(idx) / 64.0;
    
    // Initialize trajectory
    vec2 current_pos = torpedo_state.position_velocity.xy;
    vec2 current_vel = torpedo_state.position_velocity.zw;
    float orientation = torpedo_state.orientation_params.x;
    float max_accel = torpedo_state.orientation_params.z;
    
    float total_cost = 0.0;
    uint num_waypoints = 0;
    
    // Generate trajectory based on type
    if (constraints.params.x == 0.0) {  // Straight
        num_waypoints = generate_straight_trajectory(variant_param);
    } else if (constraints.params.x == 1.0) {  // Multi-angle
        num_waypoints = generate_multi_angle_trajectory(variant_param);
    } else if (constraints.params.x == 2.0) {  // Simultaneous
        num_waypoints = generate_simultaneous_trajectory(variant_param);
    }
    
    // Physics validation in parallel
    float my_violations = 0.0;
    
    for (uint i = 1; i < num_waypoints; i++) {
        vec2 wp1_pos = output.waypoints[i-1].position;
        vec2 wp2_pos = output.waypoints[i].position;
        float v1 = output.waypoints[i-1].velocity_target;
        float v2 = output.waypoints[i].velocity_target;
        
        // Check turn radius
        if (i > 1) {
            vec2 wp0_pos = output.waypoints[i-2].position;
            vec2 dir1 = normalize(wp1_pos - wp0_pos);
            vec2 dir2 = normalize(wp2_pos - wp1_pos);
            float angle_change = acos(clamp(dot(dir1, dir2), -1.0, 1.0));
            
            if (angle_change > 0.087) {  // 5 degrees
                float turn_radius = v1 * v1 / max_accel;
                float required_radius = length(wp2_pos - wp1_pos) / (2.0 * sin(angle_change / 2.0));
                
                if (turn_radius > required_radius * 1.5) {  // Safety factor
                    my_violations += (turn_radius / required_radius);
                }
            }
        }
        
        // Check velocity change feasibility
        float time_between = estimate_time_between_waypoints(i-1, i);
        float max_vel_change = max_accel * time_between;
        if (abs(v2 - v1) > max_vel_change * 1.1) {
            my_violations += abs(v2 - v1) / max_vel_change;
        }
    }
    
    // Store violations for reduction
    physics_violations[idx] = my_violations;
    barrier();
    
    // Parallel reduction to find best trajectory
    for (uint stride = 32; stride > 0; stride >>= 1) {
        if (idx < stride) {
            if (physics_violations[idx + stride] < physics_violations[idx]) {
                physics_violations[idx] = physics_violations[idx + stride];
                // Copy trajectory data if this one is better
                // ... (trajectory copying logic)
            }
        }
        barrier();
    }
    
    // Thread 0 outputs the best trajectory
    if (idx == 0) {
        output.physics_valid = (physics_violations[0] < 0.1) ? 1.0 : 0.0;
    }
}

uint generate_multi_angle_trajectory(float variant) {
    // Generate waypoints with velocity profiles
    uint wp_count = 0;
    
    // Determine if flip-burn needed based on physics
    float direct_velocity = calculate_direct_velocity();
    float turn_radius = direct_velocity * direct_velocity / torpedo_state.orientation_params.z;
    
    if (turn_radius > target_distance * 0.15) {
        // Generate flip-burn trajectory
        wp_count = generate_flip_burn_waypoints(variant);
    } else {
        // Generate curved trajectory
        wp_count = generate_curved_waypoints(variant);
    }
    
    return wp_count;
}
```

**What NOT to do**: 
- Don't ignore physics constraints in GPU calculations
- Don't generate trajectories without velocity profiles
- Don't skip validation to save GPU cycles

### **ProportionalNavigation.gd** (Component)
**Why**: PN naturally creates smooth curves through waypoints, now with velocity matching

Layer 2 guidance enhanced for velocity targets:
```gdscript
class_name ProportionalNavigation
extends Node

# Core parameters from manual tuning
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
            # Big velocity change coming up - start adjusting now
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
    
    # Natural alignment emerges from proper velocity management
    # No alignment weights needed!
    
    return {
        "turn_rate": clamp(pn_turn_rate, -torpedo_max_rotation, torpedo_max_rotation),
        "thrust": clamp(thrust, 0.2, 1.0)  # Never go below 20% thrust
    }

func calculate_thrust_for_velocity(speed_error: float, maneuver_type: String, 
                                  thrust_limit: float, max_acceleration: float) -> float:
    """Calculate thrust to achieve velocity target"""
    
    # Base thrust from velocity error
    var base_thrust = 0.5 + speed_error * velocity_gain
    
    # Maneuver-specific adjustments
    match maneuver_type:
        "burn":
            # Always maximum thrust during burns
            base_thrust = 1.0
        "curve":
            # Moderate thrust during curves
            base_thrust = clamp(base_thrust, 0.3, 0.8)
        "terminal":
            # Maximum thrust for impact
            base_thrust = 1.0
        _:
            # Normal cruise
            base_thrust = clamp(base_thrust, 0.2, 1.0)
    
    # Apply waypoint thrust limit
    return base_thrust * thrust_limit

func smooth_thrust_change(target_thrust: float) -> float:
    """Smooth thrust changes over time"""
    if abs(target_thrust - last_thrust) > 0.1:
        # Start new ramp
        thrust_ramp_start_time = Time.get_ticks_msec() / 1000.0
    
    var ramp_progress = (Time.get_ticks_msec() / 1000.0 - thrust_ramp_start_time) / thrust_smoothing
    ramp_progress = clamp(ramp_progress, 0.0, 1.0)
    
    var smoothed_thrust = lerp(last_thrust, target_thrust, ramp_progress)
    last_thrust = smoothed_thrust
    
    return smoothed_thrust
```

**Key Features**:
- Tracks both position AND velocity targets
- Anticipates upcoming velocity changes
- Natural handling of flip maneuvers
- Thrust modulation based on rotation (can't thrust efficiently while turning hard)
- NO alignment weights - proper velocity creates proper alignment

**What NOT to do**: 
- Don't add alignment weights back in
- Don't make Layer 2 decide when to flip-burn
- Don't ignore waypoint thrust limits
- Don't try to match velocity exactly - close enough is fine

### **TorpedoVisualizer.gd** (Scene-wide Overlay)
**Why**: Visual debugging shows both trajectory planning and velocity management quality

**Core Components** (enhanced from v6.1):

**Torpedo Trails** (unchanged)
- Single Line2D per torpedo
- Fixed width (2 pixels)
- Color: Cyan (#00FFFF) for all torpedoes
- Shows exact path taken by torpedo center
- Persists until next torpedo volley launches

**Waypoint Markers** (enhanced with type colors)
- Circle shapes (8 pixel radius)
- Color coding by maneuver type:
  - White (#FFFFFF): Cruise waypoints
  - Green (#00FF00): Boost/acceleration waypoints
  - Yellow (#FFFF00): Flip maneuver waypoints
  - Red (#FF0000): Burn (deceleration) waypoints
  - Blue (#0080FF): Curve approach waypoints
  - Magenta (#FF00FF): Terminal waypoints
  - Gray (#808080): Passed waypoints
- When waypoints update (1-3 Hz):
  - All waypoints briefly flash white (#FFFFFF) for 200ms
  - Flash intensity proportional to velocity error
- Final waypoint (target) always visible with pulsing animation

**Velocity Indicators** (NEW)
- Small velocity vector at each waypoint
- Length proportional to velocity_target (log scale)
- Color indicates velocity error:
  - Green: Within tolerance
  - Yellow: 500-1000 m/s error
  - Red: >1000 m/s error
- Angle shows expected heading at waypoint

**Rendering Details**:
```gdscript
func update_waypoint_markers(torpedo: Node2D):
    # Validate torpedo first
    if not is_instance_valid(torpedo):
        return
    
    var markers = waypoint_markers.get(torpedo.torpedo_id, [])
    
    # Return old markers to pool
    for marker in markers:
        if is_instance_valid(marker):
            marker.visible = false
            waypoint_pool.append(marker)
    markers.clear()
    
    # Get markers from pool for new waypoints
    for i in range(torpedo.waypoints.size()):
        if waypoint_pool.is_empty():
            break
        
        var marker = waypoint_pool.pop_back()
        var waypoint = torpedo.waypoints[i]
        
        # Color based on maneuver type
        var color = get_waypoint_color(waypoint.maneuver_type, i, torpedo)
        
        marker.color = color
        marker.global_position = waypoint.position - Vector2(8, 8)
        marker.visible = true
        markers.append(marker)
        
        # Add velocity indicator
        if velocity_indicator_pool.size() > 0:
            var vel_indicator = velocity_indicator_pool.pop_back()
            setup_velocity_indicator(vel_indicator, waypoint, torpedo)
    
    waypoint_markers[torpedo.torpedo_id] = markers
    
    # Flash based on velocity error magnitude
    var max_velocity_error = calculate_max_velocity_error(torpedo)
    flash_waypoints(markers, max_velocity_error)

func get_waypoint_color(maneuver_type: String, index: int, torpedo: Node2D) -> Color:
    # Check if passed
    if index < torpedo.current_waypoint_index:
        return Color.GRAY
    
    # Current waypoint (special handling)
    if index == torpedo.current_waypoint_index:
        return Color.GREEN  # Always green when active
    
    # Future waypoints by type
    match maneuver_type:
        "cruise": return Color.WHITE
        "boost": return Color.GREEN
        "flip": return Color.YELLOW
        "burn": return Color.RED
        "curve": return Color(0.5, 0.5, 1.0)  # Light blue
        "terminal": return Color.MAGENTA
        _: return Color.CYAN  # Fallback

func setup_velocity_indicator(indicator: Line2D, waypoint: Waypoint, torpedo: Node2D):
    # Calculate velocity vector length (log scale for visibility)
    var vel_magnitude = log(waypoint.velocity_target / 100.0) * 10.0
    var vel_direction = calculate_expected_direction(waypoint, torpedo)
    
    # Set up line
    indicator.clear_points()
    indicator.add_point(waypoint.position)
    indicator.add_point(waypoint.position + vel_direction * vel_magnitude)
    
    # Color by velocity error
    var current_velocity = torpedo.velocity_mps.length()
    var velocity_error = abs(waypoint.velocity_target - current_velocity)
    
    if velocity_error < waypoint.velocity_tolerance:
        indicator.default_color = Color.GREEN
    elif velocity_error < 1000.0:
        indicator.default_color = Color.YELLOW
    else:
        indicator.default_color = Color.RED
    
    indicator.width = 1.0
    indicator.visible = true
```

**Trail Management** (unchanged):
- Each torpedo gets one continuous line
- Line drawn from launch position through current position
- All trails cleared when new volley launches

**Implementation Notes**:
- Pure observer - reads torpedo state, never modifies
- Efficient pooling of visual elements
- Increased marker pool size to handle double waypoints
- Velocity indicators are optional (can be toggled)

**What NOT to do**: 
- Don't draw predicted paths
- Don't show physics calculations
- Don't clutter with too many indicators
- Don't make performance-heavy

### **TorpedoLauncher.gd**
**Why**: Must understand trajectory physics requirements when spawning torpedoes

Updates for physics-aware launching:
```gdscript
func fire_torpedo(target: Node2D, count: int = 8):
    # Pre-calculate if trajectories will need flip-burn
    var distance_to_target = global_position.distance_to(target.global_position)
    var physics_analysis = analyze_trajectory_requirements(target, distance_to_target)
    
    match torpedo_mode:
        TorpedoMode.MULTI_ANGLE:
            fire_multi_angle_volley(target, count, physics_analysis)
        TorpedoMode.SIMULTANEOUS:
            fire_simultaneous_volley(target, count, physics_analysis)
        _:
            fire_standard_volley(target, count)

func analyze_trajectory_requirements(target: Node2D, distance: float) -> Dictionary:
    """Pre-flight physics analysis"""
    var analysis = {
        "needs_flip_burn": false,
        "estimated_flight_time": 0.0,
        "max_achievable_angle": 0.0,
        "recommended_acceleration_profile": {}
    }
    
    # Calculate arrival velocity if constant acceleration
    var distance_meters = distance * WorldSettings.meters_per_pixel
    var arrival_velocity = sqrt(2 * 150 * 9.81 * distance_meters)
    var turn_radius = (arrival_velocity * arrival_velocity) / (150 * 9.81)
    
    # For multi-angle, check if 90° approach is possible
    if torpedo_mode == TorpedoMode.MULTI_ANGLE:
        var required_arc_distance = distance_meters * 0.3
        if turn_radius > required_arc_distance:
            analysis.needs_flip_burn = true
            analysis.estimated_flight_time = calculate_flip_burn_time(distance_meters)
        else:
            analysis.estimated_flight_time = calculate_direct_time(distance_meters)
    
    return analysis

func fire_simultaneous_volley(target: Node2D, count: int, physics_analysis: Dictionary):
    var impact_time = calculate_simultaneous_impact_time(target, count, physics_analysis)
    var angle_spacing = deg_to_rad(160.0) / float(count - 1) if count > 1 else 0
    var start_angle = -deg_to_rad(80.0)
    
    for i in range(count):
        var torpedo = create_torpedo(SmartTorpedo)
        torpedo.target = target
        
        var assigned_angle = start_angle + angle_spacing * i
        var extreme_angle = abs(assigned_angle) > deg_to_rad(60)
        
        torpedo.set_flight_plan("simultaneous", {
            "assigned_angle": assigned_angle,
            "impact_time": impact_time,
            "torpedo_index": i,
            "total_torpedoes": count,
            "requires_flip_burn": extreme_angle,  # Pre-calculated physics hint
            "physics_analysis": physics_analysis
        })
        launch_torpedo(torpedo)
```

## Tuning System v8 - Complete Manual Control

### Overview
A two-layer manual tuning system with visual preview, where Layer 1 shapes trajectories and Layer 2 controls execution quality. Both layers use manual sliders with real-time feedback through a pause-able preview mode.

### Core Principles
- **No auto-tuning complexity** - All manual sliders
- **Preview mode** - Pause at launch to see/adjust waypoints before commitment
- **Physics drives complexity** - Waypoint density based on velocity changes
- **Visual clarity** - Waypoint types shown by color
- **Parameter persistence** - Save and load tuned values

### Layer 1 - Trajectory Shaping (Manual)

Layer 1 parameters control the overall shape and strategy of the torpedo's path. These are set through manual sliders in preview mode.

#### Universal Parameters (All Trajectory Types)
```gdscript
var universal_params = {
    "waypoint_density_threshold": 0.2,  # 0.1-0.5 (velocity change % that triggers subdivision)
    "max_waypoints": 100               # 50-200 (performance limit)
}
```

#### Straight Trajectory Parameters
```gdscript
var straight_params = {
    "lateral_separation": 0.1,      # 0.0-0.5 (% of ship width between port/starboard)
    "convergence_delay": 0.8,       # 0.5-0.95 (% of flight time before paths merge)
    "initial_boost_duration": 0.15  # 0.1-0.3 (% of flight time at max thrust)
}
```

#### Multi-Angle Trajectory Parameters
```gdscript
var multi_angle_params = {
    "flip_burn_threshold": 1.2,     # 0.8-2.0 (multiplier on physics limit)
    "deceleration_target": 2000,    # 1000-5000 m/s (final velocity after burn)
    "arc_distance": 0.3,            # 0.2-0.5 (lateral offset as % of distance)
    "arc_start": 0.1,               # 0.05-0.2 (% of flight time)
    "arc_peak": 0.5,                # 0.3-0.7 (% of flight time)  
    "final_approach": 0.8           # 0.7-0.9 (% of flight time)
}
```

#### Simultaneous Impact Parameters
```gdscript
var simultaneous_params = {
    "flip_burn_threshold": 1.5,     # 0.8-2.0 (multiplier on physics limit)
    "deceleration_target": 3000,    # 1500-6000 m/s (final velocity after burn)
    "fan_out_rate": 1.0,            # 0.5-2.0 (aggressiveness of initial spread)
    "fan_duration": 0.25,           # 0.15-0.4 (% of impact time)
    "converge_start": 0.7,          # 0.6-0.85 (% of impact time)
    "converge_aggression": 1.0      # 0.5-1.5 (how hard to turn back)
}
```

### Layer 2 - Execution Control (Manual)

Layer 2 parameters control how well the torpedo follows the waypoints generated by Layer 1.

```gdscript
var execution_params = {
    "navigation_constant_N": 3.0,      # 2.0-5.0 (PN tracking aggressiveness)
    "velocity_gain": 0.001,            # 0.0005-0.003 (thrust response to velocity error)
    "velocity_anticipation": 0.5,      # 0.0-1.0 (look-ahead to next waypoint)
    "rotation_thrust_penalty": 0.5,    # 0.0-1.0 (efficiency loss while turning)
    "thrust_smoothing": 0.5,           # 0.1-1.0 seconds (0→100% thrust time)
    "position_tolerance": 100.0,       # 50-200 meters
    "velocity_tolerance": 500.0        # 200-1000 m/s
}
```

### Preview Mode Implementation

#### New Component: `TrajectoryPreviewMode.gd`
```gdscript
class_name TrajectoryPreviewMode
extends Node

# Preview state
var preview_active: bool = false
var preview_trajectories: Array = []
var preview_enabled: bool = true  # Can be toggled in settings

# References
var trajectory_planner: TrajectoryPlanner
var manual_tuning_panel: ManualTuningPanel
var torpedo_visualizer: TorpedoVisualizer

func _ready():
    # Listen for MPC tuning mode
    GameMode.mode_changed.connect(_on_mode_changed)
    
    # Find required components
    trajectory_planner = get_node("/root/TrajectoryPlanner")
    torpedo_visualizer = get_tree().get_first_node_in_group("torpedo_visualizers")

func _on_mode_changed(new_mode: GameMode.Mode):
    if new_mode == GameMode.Mode.MPC_TUNING and preview_enabled:
        # Auto-pause before torpedo launch
        get_tree().paused = true
        preview_active = true
        generate_preview_waypoints()
        show_tuning_panel()

func generate_preview_waypoints():
    """Generate waypoints for all planned torpedoes without spawning them"""
    
    # Get launch configuration
    var player_ship = get_tree().get_first_node_in_group("player_ships")
    var enemy_ship = get_tree().get_first_node_in_group("enemy_ships")
    var launcher = player_ship.get_node("TorpedoLauncher")
    
    if not launcher or not enemy_ship:
        return
    
    # Clear old previews
    preview_trajectories.clear()
    torpedo_visualizer.clear_all_waypoints()
    
    # Generate waypoints for each torpedo that would be launched
    var torpedo_count = 8  # Standard volley
    var trajectory_type = launcher.get_trajectory_mode_name()
    
    for i in range(torpedo_count):
        var launch_position = calculate_launch_position(launcher, i)
        var launch_velocity = player_ship.get_velocity_mps()
        
        # Create mock torpedo state
        var torpedo_state = {
            "position": launch_position,
            "velocity": launch_velocity,
            "orientation": player_ship.rotation,
            "trajectory_type": trajectory_type,
            "index": i,
            "total_count": torpedo_count
        }
        
        # Generate waypoints using current Layer 1 parameters
        var waypoints = trajectory_planner.generate_preview_waypoints(
            torpedo_state,
            enemy_ship,
            get_current_layer1_params()
        )
        
        preview_trajectories.append(waypoints)
        
        # Visualize immediately
        torpedo_visualizer.show_preview_waypoints(waypoints, i)

func on_slider_changed(param_name: String, value: float):
    """Called when any Layer 1 slider changes"""
    
    # Update the parameter
    update_trajectory_parameter(param_name, value)
    
    # Regenerate all preview trajectories
    generate_preview_waypoints()

func confirm_and_launch():
    """User is happy with trajectories - launch for real"""
    
    preview_active = false
    get_tree().paused = false
    
    # Hide preview waypoints
    torpedo_visualizer.hide_preview_waypoints()
    
    # Lock in Layer 1 parameters
    trajectory_planner.lock_parameters(get_current_layer1_params())
    
    # Hide tuning panel Layer 1 sliders, show Layer 2 sliders
    manual_tuning_panel.switch_to_layer2()
    
    # Trigger actual torpedo launch
    var player_ship = get_tree().get_first_node_in_group("player_ships")
    player_ship.fire_torpedoes_at_enemy()
```

### Manual Tuning Panel Updates

Extend `ManualTuningPanel.gd` to support both layers:

```gdscript
class_name ManualTuningPanel
extends Control

enum TuningLayer { LAYER1, LAYER2 }
var current_layer: TuningLayer = TuningLayer.LAYER1

# Slider containers
@onready var layer1_container: VBoxContainer = $Layer1Sliders
@onready var layer2_container: VBoxContainer = $Layer2Sliders
@onready var confirm_button: Button = $ConfirmButton

# Stored sliders for easy access
var layer1_sliders: Dictionary = {}
var layer2_sliders: Dictionary = {}

func _ready():
    create_layer1_sliders()
    create_layer2_sliders()
    
    # Start with Layer 1 visible
    layer1_container.visible = true
    layer2_container.visible = false
    confirm_button.visible = true
    
    confirm_button.pressed.connect(_on_confirm_pressed)

func create_layer1_sliders():
    var trajectory_type = get_current_trajectory_type()
    
    # Universal sliders
    add_layer1_slider("Waypoint Density", 0.1, 0.5, 0.2, "waypoint_density_threshold")
    
    match trajectory_type:
        "straight":
            add_layer1_slider("Lateral Separation", 0.0, 0.5, 0.1, "lateral_separation")
            add_layer1_slider("Convergence Delay", 0.5, 0.95, 0.8, "convergence_delay")
            add_layer1_slider("Initial Boost", 0.1, 0.3, 0.15, "initial_boost_duration")
            
        "multi_angle":
            add_layer1_slider("Flip-Burn Threshold", 0.8, 2.0, 1.2, "flip_burn_threshold")
            add_layer1_slider("Deceleration Target (m/s)", 1000, 5000, 2000, "deceleration_target")
            add_layer1_slider("Arc Distance", 0.2, 0.5, 0.3, "arc_distance")
            add_layer1_slider("Arc Start", 0.05, 0.2, 0.1, "arc_start")
            add_layer1_slider("Arc Peak", 0.3, 0.7, 0.5, "arc_peak")
            add_layer1_slider("Final Approach", 0.7, 0.9, 0.8, "final_approach")
            
        "simultaneous":
            add_layer1_slider("Flip-Burn Threshold", 0.8, 2.0, 1.5, "flip_burn_threshold")
            add_layer1_slider("Deceleration Target (m/s)", 1500, 6000, 3000, "deceleration_target")
            add_layer1_slider("Fan-Out Rate", 0.5, 2.0, 1.0, "fan_out_rate")
            add_layer1_slider("Fan Duration", 0.15, 0.4, 0.25, "fan_duration")
            add_layer1_slider("Converge Start", 0.6, 0.85, 0.7, "converge_start")
            add_layer1_slider("Converge Aggression", 0.5, 1.5, 1.0, "converge_aggression")

func create_layer2_sliders():
    add_layer2_slider("Navigation Constant N", 2.0, 5.0, 3.0, "navigation_constant_N")
    add_layer2_slider("Velocity Gain", 0.0005, 0.003, 0.001, "velocity_gain")
    add_layer2_slider("Velocity Anticipation", 0.0, 1.0, 0.5, "velocity_anticipation")
    add_layer2_slider("Rotation Thrust Penalty", 0.0, 1.0, 0.5, "rotation_thrust_penalty")
    add_layer2_slider("Thrust Smoothing (s)", 0.1, 1.0, 0.5, "thrust_smoothing")
    add_layer2_slider("Position Tolerance (m)", 50, 200, 100, "position_tolerance")
    add_layer2_slider("Velocity Tolerance (m/s)", 200, 1000, 500, "velocity_tolerance")

func add_layer1_slider(label: String, min_val: float, max_val: float, default: float, param_name: String):
    var slider = create_slider_with_label(label, min_val, max_val, default)
    layer1_sliders[param_name] = slider
    layer1_container.add_child(slider.container)
    
    slider.slider.value_changed.connect(func(value):
        # Notify preview system
        get_tree().call_group("preview_systems", "on_slider_changed", param_name, value)
    )

func add_layer2_slider(label: String, min_val: float, max_val: float, default: float, param_name: String):
    var slider = create_slider_with_label(label, min_val, max_val, default)
    layer2_sliders[param_name] = slider
    layer2_container.add_child(slider.container)
    
    slider.slider.value_changed.connect(func(value):
        # Update ProportionalNavigation parameters in real-time
        ProportionalNavigation.set(param_name, value)
    )

func switch_to_layer2():
    current_layer = TuningLayer.LAYER2
    layer1_container.visible = false
    layer2_container.visible = true
    confirm_button.visible = false  # No confirmation needed for Layer 2

func _on_confirm_pressed():
    # Notify preview system to launch
    get_tree().call_group("preview_systems", "confirm_and_launch")
```

### Waypoint Visualization Updates

Update waypoint colors to show maneuver types:

```gdscript
# In TorpedoVisualizer.gd

enum WaypointType {
    CRUISE,     # White - Standard flight
    BOOST,      # Green - Acceleration phase
    FLIP,       # Yellow - Rotation maneuver  
    BURN,       # Red - Deceleration phase
    CURVE,      # Blue - Arc maneuver
    TERMINAL    # Magenta - Final approach
}

func get_waypoint_color_for_type(type: String) -> Color:
    match type:
        "cruise": return Color.WHITE
        "boost": return Color.GREEN
        "flip": return Color.YELLOW
        "burn": return Color.RED
        "curve": return Color(0.5, 0.5, 1.0)  # Light blue
        "terminal": return Color.MAGENTA
        _: return Color.GRAY
```

### Waypoint Density Algorithm

In TrajectoryPlanner.gd:

```gdscript
func apply_adaptive_waypoint_density(waypoints: Array) -> Array:
    """Subdivide waypoints based on velocity changes"""
    if waypoints.size() < 2:
        return waypoints
    
    var densified = []
    densified.append(waypoints[0])
    
    # Get density threshold from manual tuning
    var threshold = trajectory_params.get("waypoint_density_threshold", 0.2)
    
    for i in range(1, waypoints.size()):
        var wp1 = waypoints[i-1]
        var wp2 = waypoints[i]
        
        # Check velocity change magnitude
        var vel_change = abs(wp2.velocity_target - wp1.velocity_target) / max(wp1.velocity_target, 100.0)
        
        # Check direction change
        var direction_change = 0.0
        if wp1.velocity_target > 100 and wp2.velocity_target > 100:
            var dir1 = calculate_velocity_direction(wp1)
            var dir2 = calculate_velocity_direction(wp2)
            direction_change = abs(dir1.angle_to(dir2))
        
        # Determine if subdivision needed
        var needs_subdivision = vel_change > threshold or direction_change > deg_to_rad(30)
        
        if needs_subdivision:
            # Calculate number of intermediate waypoints needed
            var subdivisions = max(
                ceil(vel_change / threshold),
                ceil(direction_change / deg_to_rad(30))
            )
            subdivisions = min(subdivisions, 5)  # Cap at 5 intermediate waypoints
            
            # Add intermediate waypoints
            for j in range(1, subdivisions):
                var t = float(j) / subdivisions
                var mid_waypoint = interpolate_waypoints(wp1, wp2, t)
                densified.append(mid_waypoint)
        
        densified.append(wp2)
    
    # Ensure we don't exceed max waypoints
    var max_waypoints = trajectory_params.get("max_waypoints", 100)
    if densified.size() > max_waypoints:
        # Intelligently reduce by removing least important waypoints
        densified = reduce_waypoint_count(densified, max_waypoints)
    
    return densified
```

### Parameter Clarifications

**Flip-burn threshold**: 
- 1.0 = Flip exactly when physics says turn is impossible
- 0.8 = Flip when turn radius exceeds 80% of safe limit (conservative)
- 1.5 = Try to curve until turn radius is 150% of limit (aggressive)

**Deceleration target**: 
- Absolute velocity in m/s after deceleration burn
- Lower = Tighter curves possible but more time vulnerable
- Higher = Gentler curves only but less vulnerable time

**Rotation thrust penalty**: 
- Applied during normal flight when turning to track waypoints
- NOT applied during flip-burn (always 0 thrust during flip)
- 0.5 = 50% thrust efficiency when at max rotation rate

### Benefits of This System

1. **Immediate Visual Feedback** - See trajectory shape before committing
2. **Physics Understanding** - Watch how parameters affect flip-burn triggers
3. **No Black Box** - Every parameter has clear visual effect
4. **Engagement Scaling** - Percentage-based parameters work at any distance
5. **Reusability** - Save successful parameter sets for similar scenarios

## Data Flow (Updated with Tuning Preview)

### Launch Sequence with Preview
1. **Player enters MPC Tuning Mode**
2. **Game auto-pauses before torpedo spawn**
3. **Preview Mode activates**:
   - Layer 1 generates waypoints for all 8 torpedoes
   - Waypoints displayed with color-coding
   - Manual tuning panel shows Layer 1 sliders
4. **Player adjusts Layer 1 sliders**:
   - Waypoints regenerate in real-time
   - Density adjusts based on velocity changes
   - Flip-burn triggers update visually
5. **Player confirms trajectory shapes**
6. **Game unpauses, torpedoes spawn**
7. **Layer 2 tuning begins**:
   - Manual panel switches to Layer 2 sliders
   - Adjust while torpedoes fly
8. **Torpedo follows waypoints** with Layer 2 guidance

### Runtime Updates (Dynamic Rate)
- **TrajectoryPlanner** recalculates at 1-3 Hz based on time-to-impact
- **Update triggers**:
  - Timer based on time-to-impact (1-3 Hz)
  - Physics violation detection (immediate)
  - Major target velocity change (immediate)
- **Preserves** current waypoint and next 2 waypoints
- **Updates** all subsequent waypoints with smooth velocity transitions
- **Validates** physics on every update
- If trajectory becomes impossible, replans with flip-burn

## Key Improvements from v6.1

- **Physics-First Design** - Turn radius calculations drive all decisions
- **Velocity Profiles** - Each waypoint has position + velocity + maneuver type
- **Flip-and-Burn** - Core maneuver for impossible trajectories, not special case
- **Natural Alignment** - Emerges from proper velocity management
- **No Alignment Weights** - Removed entire competing objective system
- **Smart Layer 1** - Full physics simulation and validation
- **Simple Layer 2** - Just tracks waypoints and matches velocities
- **Complete Validation** - Every trajectory tested for physics feasibility
- **Manual Tuning** - Direct control over both trajectory shape and execution
- **Visual Preview** - See and adjust trajectories before committing

## Critical Implementation Notes

**DO NOT**:
- Add alignment weights anywhere
- Let torpedoes fly faster than physics allows for their trajectory
- Generate more than one flip-burn per approach (two absolute maximum)
- Let Layer 2 make strategic decisions
- Update waypoints the torpedo is about to reach
- Skip physics validation to save computation
- Use auto-tuning when manual control gives better understanding

**ALWAYS**:
- Check turn radius before planning trajectories
- Validate physics on every trajectory update
- Use flip-burn when turn radius exceeds safe limits
- Let Layer 1 handle all replanning decisions
- Smooth velocity transitions between waypoints
- Trust that proper velocity creates proper alignment
- Show waypoint types through color coding
- Save successful manual tunes for reuse

The ideal result: Torpedoes that navigate like expert Expanse pilots, using flip-and-burn when physics demands it, achieving "impossible" approach angles through intelligent velocity management, all while maintaining nose-forward flight for minimum PDC vulnerability. No magic, no arbitrary limits, just physics.

## Version 8 Implementation Guide

This section provides step-by-step instructions for implementing the v8 refactor. Each step can be completed independently, allowing work to continue across multiple chat sessions.

### Prerequisites
- Back up your entire project before starting
- Ensure you have Godot 4.x with GPU compute support
- Have the v8 plan document available for reference

### Step 1: File Cleanup and Preparation

**1.1 Delete obsolete files:**
```
- Scripts/Systems/BatchMPCManager.gd
- Scripts/Systems/GPUBatchCompute.gd
- Scripts/Systems/MPCController.gd
- Scripts/Systems/MPCTuner.gd
- Scripts/Systems/MPCTuningObserver.gd
- Shaders/mpc_trajectory_batch.glsl
```

**1.2 Create backup copies of files to be heavily modified:**
```
- Scripts/Entities/Weapons/TorpedoMPC.gd → TorpedoMPC_backup.gd
- Scripts/Systems/ProportionalNavigation.gd → ProportionalNavigation_backup.gd
- Scripts/Systems/TrajectoryPlanner.gd → TrajectoryPlanner_backup.gd
```

**1.3 Check for unused variables in existing files:**
- Open each file that references deleted systems
- Search for variables like `batch_manager`, `mpc_controller`, `template_buffer`
- Comment them out with `# UNUSED v8:` prefix for now

### Step 2: Create New Base Architecture

**2.1 Create TorpedoBase.gd:**
- Location: `Scripts/Entities/Weapons/TorpedoBase.gd`
- Copy the Waypoint class definition from the v8 plan
- Implement core physics and launch system (keep lateral launch unchanged)
- Add waypoint velocity matching logic
- Ensure all exported variables have defaults

**2.2 Create StandardTorpedo.gd:**
- Location: `Scripts/Entities/Weapons/StandardTorpedo.gd`
- Extends TorpedoBase
- Implement simple waypoint generation
- Add velocity management for extreme ranges
- Test with a single torpedo launch

**2.3 Rename and refactor TorpedoMPC.gd to SmartTorpedo.gd:**
- Rename file to `SmartTorpedo.gd`
- Remove all MPC controller references
- Remove batch system integration
- Add flip-burn trajectory generation
- Add multi-angle and simultaneous methods from v8 plan

**2.4 Update scene files:**
- Open `Scenes/TorpedoMPC.tscn`
- Change script reference to SmartTorpedo.gd
- Save as `Scenes/SmartTorpedo.tscn`
- Update any prefab references in TorpedoLauncher

### Step 3: Implement Layer 1 (TrajectoryPlanner)

**3.1 Refactor TrajectoryPlanner.gd:**
- Remove all template evolution code
- Add manual parameter storage
- Implement flip-burn evaluation with threshold
- Add waypoint density algorithm
- Implement physics validation

**3.2 Create new GPU shader:**
- Location: `Shaders/trajectory_planning.glsl`
- Copy shader code from v8 plan
- Add maneuver type constants
- Implement parallel physics validation
- Test with simple trajectory first

**3.3 Add tuning parameter management:**
- Create `get_tuned_parameters()` method
- Add parameter storage/loading
- Connect to future UI system

### Step 4: Implement Layer 2 (ProportionalNavigation)

**4.1 Update ProportionalNavigation.gd:**
- Add velocity matching parameters
- Remove old alignment code
- Add flip maneuver handling
- Implement thrust smoothing
- Add anticipatory velocity control

**4.2 Remove conflicting systems:**
- Search for "alignment_weight" globally
- Remove all alignment-related calculations
- Remove template selection logic
- Ensure no competing control objectives

### Step 5: Create Tuning System UI

**5.1 Create ManualTuningPanel.gd:**
- Location: `Scripts/UI/ManualTuningPanel.gd`
- Create slider generation methods
- Add Layer 1 and Layer 2 containers
- Implement parameter binding
- Add save/load functionality

**5.2 Create TrajectoryPreviewMode.gd:**
- Location: `Scripts/Systems/TrajectoryPreviewMode.gd`
- Implement preview waypoint generation
- Add pause/unpause logic
- Connect to tuning panel
- Handle mode transitions

**5.3 Update ModeSelector:**
- Add preview mode initialization
- Ensure proper mode transitions
- Connect to new tuning system

### Step 6: Update Visualization

**6.1 Update TorpedoVisualizer.gd:**
- Add waypoint type colors
- Implement velocity indicators
- Add preview waypoint display
- Update flash behavior for velocity errors

**6.2 Create waypoint color mapping:**
- Define WaypointType enum
- Map maneuver types to colors
- Add to visualization logic

### Step 7: Integration and Testing

**7.1 Update TorpedoLauncher.gd:**
- Add physics pre-analysis
- Update volley methods for new torpedo types
- Ensure proper parameter passing
- Test each trajectory type

**7.2 Update GameMode and battle flow:**
- Ensure MPC_TUNING mode works with preview
- Test mode transitions
- Verify pause/unpause behavior

**7.3 Scene updates needed:**
- Add ManualTuningPanel to UI layer
- Ensure TrajectoryPlanner is autoloaded
- Update torpedo prefabs
- Test preview visualization

### Step 8: Final Cleanup and Validation

**8.1 Remove all unused variables:**
- Search for variables marked with `# UNUSED v8:`
- Delete them permanently
- Check for orphaned imports
- Run Godot's script analyzer

**8.2 Validate physics calculations:**
- Test flip-burn triggers at different ranges
- Verify waypoint density adaptation
- Check velocity profile smoothness
- Ensure no impossible trajectories

**8.3 Performance validation:**
- Profile GPU shader performance
- Check waypoint generation time
- Verify 60 FPS maintained
- Test with maximum torpedo count

### Completion Checklist

After each step, verify:
- [ ] No script errors in Godot console
- [ ] Game runs without crashes
- [ ] Deleted files are truly gone
- [ ] No references to removed systems
- [ ] New features work as intended
- [ ] Physics behavior matches v8 plan
- [ ] UI elements appear correctly
- [ ] Saved parameters persist

### Troubleshooting Common Issues

**"Node not found" errors:**
- Check scene tree paths
- Verify autoload order
- Use `get_node_or_null()` with validation

**Physics violations:**
- Check unit conversions (meters vs pixels)
- Verify turn radius calculations
- Ensure proper frame-rate independence

**GPU shader not working:**
- Check shader compilation errors
- Verify binding points
- Test with CPU fallback first

**Waypoints not appearing:**
- Check visualization layer order
- Verify color assignments
- Ensure proper validation in visualizer

This implementation can be paused at any step. When resuming, start by running the game and checking for errors, then continue from the last completed step.