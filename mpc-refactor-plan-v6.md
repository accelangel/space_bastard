# MPC Torpedo System Refactoring Plan v6.1 - Complete

## The Problem
The current MPC system is overcomplicated and fights against physics. Torpedoes oscillate between templates, can't hit stationary targets, and the "MPC" is really just template selection. The system tries to recalculate everything every frame instead of committing to a plan and following it smoothly. Templates are parameter sets, not actual trajectories, leading to jerky, unpredictable motion.

## The Solution
A true layered guidance system where GPU-based trajectory planning (Layer 1) generates physically-achievable waypoint paths and updates them intelligently, while simple proportional navigation (Layer 2) smoothly flies through them. The torpedo's actual path naturally interpolates through the waypoints due to physics - ideally approaching an interpolating polynomial without forcing it. Smart planning, smooth execution.

## Critical Design Consideration: Terminal Alignment

### The Sideways Torpedo Problem
In realistic space combat, a torpedo's orientation relative to its velocity vector is crucial for survivability. When a torpedo is flying sideways (high orientation-velocity error), several problems occur:

1. **Visual Absurdity**: Torpedoes look ridiculous sliding sideways through space like drifting cars. They should fly nose-first like arrows or bullets.

2. **Massive PDC Target**: A torpedo presents different cross-sections depending on alignment:
   - Nose-on: ~1m² cross-section (just the warhead diameter)
   - Sideways: ~10-20m² cross-section (full length × width)
   - This is a 10-20x larger target for PDC streams!

3. **Terminal Phase Vulnerability**: In the last 500m of flight, PDCs have their best chance to intercept. A misaligned torpedo is practically asking to be shot down.

### The Solution: Velocity Alignment Blending
Layer 2 (ProportionalNavigation) continuously blends between two goals:
- Following waypoints to reach the target (primary)
- Aligning orientation with velocity vector (secondary but critical)

This creates natural, arrow-like flight paths where torpedoes automatically nose-forward, especially important during terminal approach. Different torpedo types need different alignment weights based on their flight patterns.

## Physics Constraints & Requirements

### What We Accept
- **Forward-only thrust** (torpedoes can't thrust sideways)
- **Continuous acceleration** (30G baseline, up to 150G)
- **No speed limit** (except speed of light)
- **20-100% throttle range** (no braking, no reverse)
- **Natural physics behavior** (turn radius = v²/a_lateral emerges from physics engine)
- **Ideal path is interpolating polynomial through waypoints** (emerges naturally from inertia)
- **Lateral launch ejection** (all torpedoes launch sideways from tubes before main engine ignition)

### What We DON'T Want
- Arbitrary speed caps
- Constant throttle cutting (occasional is fine)
- Sharp 90° turns at waypoints
- Oscillating/hunting behavior
- Different physics for different torpedo types
- Forcing polynomial following (let physics create it naturally)
- **Sideways terminal approaches** (torpedoes must align with velocity before impact)

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
- Waypoints returned as positions, not node references
- Validate torpedo still exists before applying updates

**ProportionalNavigation**:
- No stored reference to "current waypoint node"
- Calculate fresh each frame from waypoint position array
- Validate torpedo exists before calculating guidance

**TorpedoVisualizer**:
- Trail nodes might be freed - check is_instance_valid()
- Waypoint markers are visual only - don't rely on them for logic
- Clear all visuals when torpedo dies, don't assume they'll clean themselves

**SimpleAutoTuner**:
- Don't track torpedoes across cycles
- Count hits/misses through event observation, not direct tracking
- Ship reset positions are fresh teleports, not state preservation

This architecture principle overrides any implementation detail that would violate it. When in doubt: query fresh, validate everything, trust nothing across frames.

## Files to DELETE

### Complete Removal
- `BatchMPCManager.gd` - replaced by TrajectoryPlanner
- `GPUBatchCompute.gd` - replaced by cleaner GPU planner
- `MPCController.gd` - no longer needed
- `MPCTuner.gd` - no tuning system needed
- `MPCTuningObserver.gd` - no tuning system needed
- `mpc_trajectory_batch.glsl` - replaced with trajectory planning shader

### Heavy Modification
- `TorpedoMPC.gd` - becomes SmartTorpedo.gd (90% rewrite)

## New Architecture

### **TorpedoBase.gd**
**Why**: Shared foundation prevents code duplication and ensures consistent physics and launch behavior

Provides ALL torpedoes with:
- Core physics state (position, velocity, orientation)
- Thrust and rotation application
- **Lateral launch system**:
  - All torpedoes eject sideways from launch tubes
  - Initial lateral velocity (60 m/s default)
  - Main engine ignition delay (1.6 seconds)
  - Engines ignite after traveling 80m laterally OR after timeout
  - Creates realistic tube-launch behavior
- Trail rendering
- Waypoint storage and current waypoint tracking (with double waypoints for protection zone)
- Waypoint acceptance logic:
  ```gdscript
  @export var acceptance_radius: float = 100.0  # meters
  @export var waypoint_timeout: float = 10.0    # seconds per waypoint
  
  func check_waypoint_advance():
      if current_waypoint_index >= waypoints.size() - 1:
          return  # Already at final waypoint
      
      var current_waypoint = waypoints[current_waypoint_index]
      var to_waypoint = current_waypoint - global_position
      var distance = to_waypoint.length()
      
      # Convert to meters for acceptance check
      var distance_meters = distance * WorldSettings.meters_per_pixel
      
      # Three conditions for advancing
      if distance_meters < acceptance_radius:
          advance_waypoint("reached")
      elif to_waypoint.dot(velocity) < 0:
          advance_waypoint("passed")
      elif Time.get_ticks_msec() / 1000.0 - waypoint_start_time > waypoint_timeout:
          advance_waypoint("timeout")
  
  func advance_waypoint(reason: String):
      current_waypoint_index += 1
      waypoint_start_time = Time.get_ticks_msec() / 1000.0
      emit_signal("waypoint_reached", current_waypoint_index - 1, reason)
  ```
- Debug state (show waypoints, acceptance circles, etc)

**What NOT to do**: Don't put trajectory-specific logic here. This is only shared physics, launch behavior, and visualization.

### **StandardTorpedo.gd** (extends TorpedoBase)
**Why**: Even simple torpedoes benefit from waypoint visualization and consistent guidance

Simple direct-attack torpedo:
- Gets 6 waypoints on launch (increased for protection zone safety):
  - Initial slight offset (based on launch side)
  - 4 intermediate alignment points for smooth path
  - Target (continuously updated each frame)
- Implementation:
  ```gdscript
  func generate_waypoints():
      var to_target = target.global_position - global_position
      var distance = to_target.length()
      
      waypoints.clear()
      
      # Initial offset to clear launching ship
      var offset_dir = Vector2.UP.rotated(launcher.rotation + launch_side * PI/2)
      waypoints.append(global_position + offset_dir * 100)
      
      # Multiple intermediate points for smooth path (protection zone safety)
      for i in range(1, 5):  # 4 intermediate points
          var t = float(i) / 5.0
          var intermediate_pos = global_position + to_target * t
          # Small lateral offset that decays
          var lateral_offset = offset_dir * (100 * (1.0 - t))
          waypoints.append(intermediate_pos + lateral_offset)
      
      # Target (will update each frame)
      waypoints.append(target.global_position)
  ```
- Uses same Layer 2 guidance as smart torpedoes
- Full visualization support

**What NOT to do**: Don't make these use different physics or guidance laws. Consistency is key.

### **SmartTorpedo.gd** (extends TorpedoBase)
**Why**: Complex trajectories need more waypoints but same underlying guidance

Advanced multi-role torpedo supporting:

**Multi-Angle Attack**:
- Port torpedo: Arc left to hit target from 90° left
- Starboard torpedo: Arc right to hit target from 90° right
- Result: Perpendicular impact vectors
- Exactly 31 waypoints (30 arc points + final target)
```gdscript
func generate_multi_angle_waypoints():
    var to_target = target.global_position - global_position
    var distance = to_target.length()
    var perpendicular = to_target.rotated(approach_side * PI/2).normalized()
    
    waypoints.clear()
    
    # Arc out perpendicular to target line - double waypoints for safety
    for i in range(30):  # Was 15, now 30 for protection zone
        var t = float(i) / 29.0
        var arc_factor = sin(t * PI) * arc_radius_factor
        var forward_progress = t
        
        var pos = global_position
        pos += to_target * forward_progress
        pos += perpendicular * arc_factor * distance
        
        waypoints.append(pos)
    
    # Final approach from 90° angle
    waypoints.append(target.global_position)
```

**Simultaneous Impact**:
- Dynamically divides 160° cone based on number of torpedoes
- 2 torpedoes: 160° apart (impact from ±80°)
- 4 torpedoes: ~53° apart (impact from ±80°, ±27°)
- 8 torpedoes: ~23° apart (impact from ±80°, ±57°, ±34°, ±11°)
- N torpedoes: 160°/(N-1) spacing between adjacent torpedoes
- All must impact at same time T
- Inner angles get longer spiral paths to waste time
- Up to 42 waypoints typical (up to 16 fan + 24 spiral + 2 final)
```gdscript
func generate_simultaneous_waypoints(assigned_angle: float, impact_time: float):
    # Calculate required path length based on impact time
    var direct_distance = global_position.distance_to(target.global_position)
    var required_path_length = velocity.length() * impact_time
    var excess_path = required_path_length - direct_distance
    
    waypoints.clear()
    
    # Fan out phase - double waypoints
    var fan_direction = Vector2.UP.rotated(assigned_angle)
    for i in range(16):  # Was 8, now 16 for protection zone
        var t = float(i) / 15.0 * fan_spread_rate
        waypoints.append(global_position + fan_direction * t * 500)
    
    # Spiral phase if need to waste time - double waypoints
    if excess_path > 0:
        var spiral_center = waypoints[-1]
        var spiral_radius = excess_path / (2 * PI * spiral_expansion)
        for i in range(24):  # Was 12, now 24 for protection zone
            var angle = float(i) / 24.0 * TAU * spiral_expansion
            var pos = spiral_center + Vector2.from_angle(angle) * spiral_radius
            waypoints.append(pos)
    
    # Convergence phase
    var final_approach_dir = Vector2.from_angle(assigned_angle)
    waypoints.append(target.global_position - final_approach_dir * 1000)
    waypoints.append(target.global_position)
```

**What NOT to do**: Don't add special physics here. Complexity comes from waypoints, not different flight models.

### **TrajectoryPlanner.gd** (Singleton)
**Why**: GPU acceleration makes complex trajectory optimization feasible in real-time

GPU-accelerated trajectory optimization that:
- Receives planning requests with constraints
- Generates physically-achievable waypoint paths
- **Dynamic update rate based on time-to-impact**:
  - 15+ seconds to impact: 1 Hz updates
  - 10 seconds to impact: 2 Hz updates  
  - 5 seconds to impact: 3 Hz updates (max)
- **Only updates waypoints AFTER the immediate upcoming waypoint** (preserves smooth flight)

#### The Near-Waypoint Edge Case Problem
**Why this matters**: Imagine a torpedo is 1 meter from reaching waypoint N. We protect waypoint N from updates (good!), but we update waypoint N+1 based on new target position. Next frame, the torpedo reaches waypoint N and immediately starts heading toward waypoint N+1... which might now be in a completely different direction! This causes exactly the jerky, discontinuous motion we're trying to avoid.

**The Solution**: Double waypoints + Extended protection zone
- Generate **double the waypoints** for all trajectory types (30-40 for multi-angle, 40-60 for simultaneous)
- Protect the **next 2 waypoints** instead of just 1
- Simple, robust, no complex math

**Implementation**:
```gdscript
func update_torpedo_waypoints(torpedo: SmartTorpedo):
    var new_waypoints = generate_waypoints_gpu(torpedo)
    
    # Protect current waypoint AND the next TWO after it
    var current_idx = torpedo.current_waypoint_index
    var protected_until = min(current_idx + 3, torpedo.waypoints.size())  # +3 to protect current + next 2
    
    # Only update waypoints after the protection zone
    for i in range(protected_until, new_waypoints.size()):
        if i < torpedo.waypoints.size():
            torpedo.waypoints[i] = new_waypoints[i]
        else:
            torpedo.waypoints.append(new_waypoints[i])
    
    torpedo.last_waypoint_update = Time.get_ticks_msec() / 1000.0
```

**Why not use complex solutions**: We could calculate if the torpedo will reach the waypoint before next update, or blend waypoint positions, or use predictive locking... but why? More waypoints + larger protection zone achieves the same smooth flight with zero complexity. The GPU can handle double the waypoints trivially, and the behavior is completely predictable.

- Accounts for:
  - Continuous acceleration effects
  - Natural turn radius at predicted speeds
  - Approach angle requirements (90° for multi-angle)
  - Simultaneous impact timing
  - Target movement prediction
- Returns waypoint arrays
- No caching - fresh calculations for current conditions

Implementation:
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
    
    return time_since_last >= (1.0 / update_rate)
```

**What NOT to do**: 
- Don't update waypoint torpedo is currently approaching OR the next two after it
- Don't generate physically impossible paths
- Don't over-update in terminal phase when path is essentially straight
- Don't store torpedo references - validate on every access
- Don't try complex predictive algorithms when simple protection zones work better

### **trajectory_planning.glsl**
**Why**: Parallel evaluation of thousands of trajectory variations in milliseconds

GPU compute shader that:
- Simulates full trajectory with proper physics
- For multi-angle: Ensures 90° perpendicular approach
- For simultaneous: Calculates path lengths to match impact time
- Optimizes waypoint placement for smooth curves
- Ensures all paths are achievable at 20%+ throttle

Implementation:
```glsl
#version 450

layout(local_size_x = 64) in;

// Each thread tests a different trajectory variant
void main() {
    uint variant_id = gl_GlobalInvocationID.x;
    
    // Initialize trajectory state
    vec2 pos = torpedo_start_pos;
    vec2 vel = torpedo_start_vel;
    float orientation = torpedo_start_orientation;
    
    float total_cost = 0.0;
    
    // Simulate trajectory forward
    for (int step = 0; step < MAX_STEPS; step++) {
        // Calculate control based on variant parameters
        float turn_rate = calculate_turn_rate(variant_id, pos, vel, orientation);
        float thrust = max(0.2, calculate_thrust(variant_id, turn_rate));
        
        // Update physics
        orientation += turn_rate * dt;
        vec2 thrust_dir = vec2(cos(orientation), sin(orientation));
        vec2 accel = thrust_dir * thrust * max_acceleration;
        vel += accel * dt;
        pos += vel * dt;
        
        // Accumulate cost
        vec2 to_target = target_pos + target_vel * float(step) * dt - pos;
        total_cost += length(to_target);
    }
    
    // Store result
    trajectory_costs[variant_id] = total_cost;
}
```

**What NOT to do**: Don't ignore physics constraints. Every path must be flyable.

### **ProportionalNavigation.gd** (Component)
**Why**: PN naturally creates smooth curves through waypoints without forcing polynomial following

Layer 2 guidance used by ALL torpedoes with **velocity alignment** for survivability:
```gdscript
class_name ProportionalNavigation
extends Node

var N: float = 3.0  # Navigation constant
var last_los_angle: float = 0.0
var first_frame: bool = true

func calculate_guidance(torpedo_pos: Vector2, torpedo_vel: Vector2, 
                       torpedo_orientation: float,
                       target_pos: Vector2, target_vel: Vector2,
                       alignment_weight: float = 0.3) -> Dictionary:
    # Line of sight vector
    var los = target_pos - torpedo_pos
    var los_angle = los.angle()
    
    # First frame initialization
    if first_frame:
        last_los_angle = los_angle
        first_frame = false
        return {"turn_rate": 0.0, "thrust": 1.0}
    
    # Calculate LOS rate
    var los_rate = angle_difference(los_angle, last_los_angle) / get_physics_process_delta_time()
    last_los_angle = los_angle
    
    # Closing velocity
    var closing_velocity = -torpedo_vel.dot(los.normalized())
    
    # PN guidance law for target tracking
    var commanded_acceleration = N * closing_velocity * los_rate
    var perpendicular_accel = commanded_acceleration
    var pn_turn_rate = perpendicular_accel / torpedo_vel.length()
    
    # Velocity alignment control
    var velocity_angle = torpedo_vel.angle()
    var orientation_error = angle_difference(torpedo_orientation, velocity_angle)
    var alignment_turn_rate = orientation_error * 5.0  # Aggressive alignment gain
    
    # Blend between target tracking and velocity alignment
    var final_turn_rate = (pn_turn_rate * (1.0 - alignment_weight)) + 
                          (alignment_turn_rate * alignment_weight)
    
    # Thrust modulation based on required turn
    var normalized_turn = abs(final_turn_rate) / torpedo.max_rotation_rate
    var thrust = 1.0 - (normalized_turn * 0.5)  # Reduce thrust by up to 50% in hard turns
    thrust = max(0.2, thrust)  # Never below 20%
    
    return {
        "turn_rate": clamp(final_turn_rate, -torpedo.max_rotation_rate, torpedo.max_rotation_rate),
        "thrust": thrust
    }
```

**Key Features**:
- Continuously blends target tracking with nose-forward alignment
- Different torpedo types use different alignment weights (tuned parameter)
- Natural flow through waypoints (no stopping)
- Creates arrow-like flight paths automatically

**What NOT to do**: 
- Don't force specific paths - let physics create them
- Don't stop at waypoints - flow through them
- Don't ignore velocity alignment - it's critical for survival

### **TorpedoVisualizer.gd** (Scene-wide Overlay)
**Why**: Visual debugging instantly shows planning vs execution quality without modifying torpedo behavior

**Core Components**:

**Torpedo Trails**
- Single Line2D per torpedo
- Fixed width (2 pixels)
- Color: Cyan (#00FFFF) for all torpedoes
- Shows exact path taken by torpedo center
- Persists until next torpedo volley launches
- No fading, no width changes, no heat mapping

**Waypoint Markers**
- Circle shapes (8 pixel radius)
- Three colors only:
  - Gray (#808080): Passed waypoints
  - Green (#00FF00): Current target waypoint  
  - Cyan (#00FFFF): Future waypoints
- When waypoints update (1-3 Hz):
  - All waypoints briefly flash white (#FFFFFF) for 200ms
  - Simple visual confirmation of replanning
- Final waypoint (target) always visible

**Rendering Details**:
- Rendered on separate CanvasLayer above game objects
- All trails batched into single draw call
- All waypoints of same color batched together
- Updates only when waypoints change (1-3 Hz max)
- Torpedo physics runs at 60 Hz but visualizer updates waypoints at their actual update rate

**Implementation**:
```gdscript
class_name TorpedoVisualizer
extends CanvasLayer

var torpedo_trails: Dictionary = {}  # torpedo_id -> Line2D
var waypoint_markers: Dictionary = {} # torpedo_id -> Array[ColorRect]
var waypoint_pool: Array = []  # Reusable markers

func _ready():
    layer = 1  # Above game objects
    
    # Pre-create marker pool - increased for double waypoints
    for i in range(1000):  # Was 500, now 1000 to support double waypoint counts
        var marker = ColorRect.new()
        marker.size = Vector2(16, 16)  # 8 pixel radius = 16x16 square
        marker.pivot_offset = Vector2(8, 8)
        marker.visible = false
        add_child(marker)
        waypoint_pool.append(marker)

func on_torpedo_spawned(torpedo: Node2D):
    # Create trail
    var trail = Line2D.new()
    trail.width = 2.0
    trail.default_color = Color.CYAN
    trail.add_point(torpedo.global_position)
    add_child(trail)
    torpedo_trails[torpedo.torpedo_id] = trail
    
    # Initialize waypoint markers
    waypoint_markers[torpedo.torpedo_id] = []
    update_waypoint_markers(torpedo)

func _physics_process(_delta):
    # Update trails
    for torpedo_id in torpedo_trails:
        var torpedo = get_torpedo_by_id(torpedo_id)
        if torpedo and is_instance_valid(torpedo):
            var trail = torpedo_trails[torpedo_id]
            trail.add_point(torpedo.global_position)

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
        var waypoint_pos = torpedo.waypoints[i]
        
        # Color based on status
        if i < torpedo.current_waypoint_index:
            marker.color = Color.GRAY
        elif i == torpedo.current_waypoint_index:
            marker.color = Color.GREEN
        else:
            marker.color = Color.CYAN
        
        marker.global_position = waypoint_pos - Vector2(8, 8)
        marker.visible = true
        markers.append(marker)
    
    waypoint_markers[torpedo.torpedo_id] = markers
    
    # Flash white briefly
    flash_waypoints(markers)

func flash_waypoints(markers: Array):
    for marker in markers:
        if is_instance_valid(marker):
            var original_color = marker.color
            marker.color = Color.WHITE
            
            # Restore color after 200ms
            await get_tree().create_timer(0.2).timeout
            if is_instance_valid(marker):
                marker.color = original_color
```

**Trail Management**:
- Each torpedo gets one continuous line that extends as it flies
- Line drawn from launch position through current position
- When new volley launches:
  - All existing trails cleared instantly
  - All existing waypoint markers cleared
  - Fresh start for new volley

**Implementation Notes**:
- Pure observer - reads torpedo state, never modifies
- Connects to torpedo spawn/death signals
- Maintains dictionary of torpedo_id -> trail node
- Efficient pooling of waypoint marker nodes
- No interactive elements
- No LOD system
- No performance modes

**What NOT to do**: 
- Don't draw lines between waypoints
- Don't show acceptance circles
- Don't add text labels or numbers
- Don't make it interactive
- Don't vary visual style by torpedo type

### **TorpedoLauncher.gd**
**Why**: Minimal changes preserve existing launch mechanics

Updates:
- For multi-angle: Assign perpendicular approach sides
- For simultaneous: Calculate angle distribution based on torpedo count
- Pass constraints to torpedo on spawn

```gdscript
func fire_torpedo(target: Node2D, count: int = 8):
    match torpedo_mode:
        TorpedoMode.MULTI_ANGLE:
            fire_multi_angle_volley(target, count)
        TorpedoMode.SIMULTANEOUS:
            fire_simultaneous_volley(target, count)
        _:
            fire_standard_volley(target, count)

func fire_simultaneous_volley(target: Node2D, count: int):
    var impact_time = calculate_impact_time(target)
    var angle_spacing = deg_to_rad(160.0) / float(count - 1) if count > 1 else 0
    var start_angle = -deg_to_rad(80.0)
    
    for i in range(count):
        var torpedo = create_torpedo(SmartTorpedo)
        torpedo.target = target
        torpedo.set_flight_plan("simultaneous", {
            "assigned_angle": start_angle + angle_spacing * i,
            "impact_time": impact_time,
            "torpedo_index": i,
            "total_torpedoes": count
        })
        launch_torpedo(torpedo)
```

## Tuning System

### **SimpleAutoTuner.gd** (Layer 2 Parameter Optimization)
**Why**: Even with a good design, proportional navigation constants need tuning for each torpedo type

**Core Functionality**:
- Select torpedo type to tune (Straight/Multi-Angle/Simultaneous)
- Enemy ship accelerates straight down at 6G from starting position
- Auto-fire waits for all torpedoes to complete (hit/miss/timeout) then resets ships
- Manual fire button for when auto-fire is disabled
- Simple hill-climbing optimization (try parameter, measure, go up/down based on results)

**Implementation**:
```gdscript
var current_parameters: Dictionary = {}
var best_parameters: Dictionary = {}
var best_performance: float = 0.0
var tuning_step: float = 0.1
var current_param_index: int = 0

func run_tuning_cycle():
    # Fire volley with current parameters
    apply_parameters_to_torpedoes(current_parameters)
    fire_test_volley()
    
    # Wait for all torpedoes to complete
    await all_torpedoes_complete
    
    # Measure performance
    var performance = calculate_performance()
    
    # Hill climbing
    if performance > best_performance:
        best_performance = performance
        best_parameters = current_parameters.duplicate()
        # Keep going in same direction
        modify_current_parameter(tuning_step)
    else:
        # Reverse direction and reduce step size
        tuning_step *= -0.8
        modify_current_parameter(tuning_step)
        
        # Move to next parameter if step too small
        if abs(tuning_step) < 0.01:
            current_param_index = (current_param_index + 1) % current_parameters.size()
            tuning_step = 0.1

func calculate_performance() -> float:
    var total_score = 0.0
    
    for result in torpedo_results:
        if result.hit:
            total_score += 100.0
            # CRITICAL: Bonus for good terminal alignment
            if result.terminal_alignment_error < deg_to_rad(5):
                total_score += 50.0  # Huge bonus for nose-on impact
        else:
            # Inverse miss distance scoring
            var miss_penalty = min(result.miss_distance / 100.0, 50.0)
            total_score += 50.0 - miss_penalty
            
            # Extra penalty for sideways approaches that missed
            if result.terminal_alignment_error > deg_to_rad(30):
                total_score -= 25.0  # Suggests torpedo was easy PDC target
    
    return total_score / torpedo_results.size()
```

**Layer 2 Tuned Parameters by Type**:

**Straight Torpedoes**:
- `navigation_constant_N`: Core PN parameter (2.0-4.0 range)
- `waypoint_acceptance_radius`: Base acceptance radius (10-50m)
- `alignment_weight`: Balance between tracking and nose-forward (0.1-0.5 range)
  - Lower values since they're already flying pretty straight

**Multi-Angle Torpedoes**:
- `navigation_constant_N`: Core PN parameter (3.0-5.0 range)
- `waypoint_acceptance_radius`: Base acceptance radius (20-100m)
- `arc_tracking_boost`: Extra PN gain during arc phase (1.0-2.0)
- `alignment_weight`: Balance between tracking and nose-forward (0.2-0.6 range)
  - Higher values since they're doing 90° approaches and need to straighten out

**Simultaneous Impact Torpedoes**:
- `navigation_constant_N`: Core PN parameter (2.5-4.5 range)
- `waypoint_acceptance_radius`: Base acceptance radius (30-150m)
- `spiral_tracking_factor`: PN reduction during spirals (0.5-1.0)
- `convergence_boost`: PN boost during final convergence (1.0-2.0)
- `alignment_weight`: Balance between tracking and nose-forward (0.2-0.5 range)
  - Medium values, especially important after spiral phase

**Failure Handling**:
- Torpedo leaving map = counted as miss with 99999m miss distance
- Timeout after 60 seconds = miss
- Destruction reason "ship_impact" = hit
- All other destruction reasons = miss
- Cycle resets when all torpedoes accounted for

**Data Storage**:
- Saves tuned parameters per torpedo type
- Exports to simple config file
- Parameters loaded automatically on game start

### **ManualTuningPanel.gd** (Layer 1 Trajectory Shaping)
**Why**: Layer 1 trajectory generation has artistic/tactical parameters that need human judgment

**Implementation**:
```gdscript
extends Panel

@onready var slider_container = $VBoxContainer
var current_torpedo_type: String = "straight"
var sliders: Dictionary = {}

func setup_sliders_for_type(type: String):
    # Clear existing sliders
    for child in slider_container.get_children():
        child.queue_free()
    sliders.clear()
    
    match type:
        "straight":
            add_slider("initial_offset_angle", -30, 30, 0)
            
        "multi_angle":
            add_slider("arc_radius_factor", 0.3, 0.8, 0.5)
            add_slider("arc_commit_point", 0.6, 0.9, 0.8)
            
        "simultaneous":
            add_slider("fan_spread_rate", 0.5, 2.0, 1.0)
            add_slider("spiral_expansion", 0.0, 1.0, 0.5)
            add_slider("convergence_timing", 0.5, 0.8, 0.7)

func add_slider(param_name: String, min_val: float, max_val: float, default: float):
    var container = HBoxContainer.new()
    
    var label = Label.new()
    label.text = param_name.capitalize()
    label.custom_minimum_size.x = 150
    
    var slider = HSlider.new()
    slider.min_value = min_val
    slider.max_value = max_val
    slider.value = default
    slider.step = 0.01
    
    var value_label = Label.new()
    value_label.text = "%.2f" % default
    value_label.custom_minimum_size.x = 50
    
    slider.value_changed.connect(func(value):
        value_label.text = "%.2f" % value
        TrajectoryPlanner.set_parameter(current_torpedo_type, param_name, value)
    )
    
    container.add_child(label)
    container.add_child(slider)
    container.add_child(value_label)
    slider_container.add_child(container)
    
    sliders[param_name] = slider
```

**Layer 1 Manual Sliders by Type**:

**Straight Torpedoes**:
- `initial_offset_angle` (-30° to +30°): Launch angle offset for clearing ship

**Multi-Angle Torpedoes**:
- `arc_radius_factor` (0.3-0.8): How far out the arc extends (% of distance to target)
- `arc_commit_point` (0.6-0.9): When to stop arcing and turn toward target

**Simultaneous Impact Torpedoes**:
- `fan_spread_rate` (0.5-2.0): How quickly torpedoes fan out
- `spiral_expansion` (0.0-1.0): How much to spiral for time wasting (0=straight to position)
- `convergence_timing` (0.5-0.8): When to start final convergence (% of flight time)

**Interface**:
- Tabs or dropdown to select torpedo type
- Shows only relevant sliders for selected type
- Changes apply immediately to new torpedoes
- Reset to defaults button

## Data Flow

### Launch Sequence
1. **Launcher** creates torpedo with type and constraints
2. **Torpedo** asks TrajectoryPlanner for waypoints
3. **TrajectoryPlanner** GPU-optimizes path, returns waypoints
4. **Torpedo** begins following waypoints with PN
5. **Visualizer** displays waypoints and trail

### Runtime Updates (Dynamic Rate)
- **TrajectoryPlanner** recalculates at 1-3 Hz based on time-to-impact
- **Update triggers**:
  - Timer based on time-to-impact (1-3 Hz)
- **Preserves** current waypoint and next 2 waypoints (no jerky changes)
- **Updates** all subsequent waypoints based on new target position
- Final waypoint tracks target every frame
- White flash shows replanning occurred

## Key Improvements
- **Physics-based** - turn radius naturally emerges from forward-only thrust constraint
- **Smart replanning** - updates future path without disrupting current maneuver
- **Dynamic update rate** - more frequent updates when accuracy matters most
- **Natural curves** - PN + inertia creates polynomial-like paths without forcing
- **Specific attack patterns** - 90° perpendicular hits, flexible N-torpedo simultaneous impacts
- **Visual clarity** - waypoint dots show intent, trail shows execution
- **Zero-trust architecture** - never assumes references remain valid across frames
- **Double waypoint protection** - double waypoints + 2-waypoint protection zone eliminates edge-case jerkiness
- **Terminal alignment** - torpedoes naturally fly nose-first, reducing PDC vulnerability by 10-20x

The ideal result is torpedo trails that look like smooth interpolating polynomials through the waypoints, achieved naturally through physics rather than mathematical forcing, with torpedoes that always face forward like proper projectiles should.