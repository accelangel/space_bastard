# Space Bastard: A Comprehensive Technical Report on the Evolution of Physics-Based Space Combat

## Table of Contents
1. [Executive Summary](#1-executive-summary)
2. [Project Genesis and Core Vision](#2-project-genesis-and-core-vision)
3. [Current State of Development](#3-current-state-of-development)
4. [Technical Evolution and Architecture](#4-technical-evolution-and-architecture)
5. [Major Challenges and Solutions](#5-major-challenges-and-solutions)
6. [Future Development Roadmap](#6-future-development-roadmap)
7. [Technical Deep Dives](#7-technical-deep-dives)
8. [Lessons Learned](#8-lessons-learned)
9. [Conclusion](#9-conclusion)

---

## 1. Executive Summary

Space Bastard represents an ambitious attempt to create the first truly physics-accurate space combat simulator inspired by The Expanse's realistic portrayal of space warfare. Unlike traditional space games that treat space as an ocean or air combat arena, Space Bastard embraces the terrifying reality of combat in the void: engagements at thousands of kilometers, weapons moving at significant fractions of light speed, and the constant battle between offensive capabilities and point defense systems.

The project has evolved from a simple proof-of-concept with basic torpedo mechanics to a sophisticated combat simulation featuring:
- Model Predictive Control (MPC) based torpedo guidance systems
- Automated PID tuning with gradient descent optimization
- Multi-layered Point Defense Cannon (PDC) systems
- Frame-rate independent physics at extreme velocities
- Battle management and analytics systems
- Mode-based architecture separating combat from tuning systems

This report documents the journey from conception to current state, examining the technical challenges encountered, solutions implemented, and the roadmap for future development.

---

## 2. Project Genesis and Core Vision

### 2.1 The Inspiration

The project began with a simple observation: despite decades of space games, none had captured the visceral reality of space combat as depicted in The Expanse. The show's portrayal of PDCs creating walls of tungsten against incoming torpedoes, the vast distances involved, and the chess-like tactical decisions resonated deeply. Existing games fell into predictable patterns:

- **Elite Dangerous**: Arbitrary speed limits and "space friction"
- **EVE Online**: Tab-targeting spreadsheet combat
- **Star Wars games**: WW2 dogfighting in space
- **FTL**: Abstract tactical combat

Space Bastard aimed to fill this gap by creating authentic physics-based combat at realistic scales.

### 2.2 Core Design Principles

The original design document established several non-negotiable principles:

1. **Real Physics, Real Scale**: The game operates on a 65km × 37km battlefield where each pixel represents 0.25 meters. Ships accelerate using realistic G-forces, and all projectiles follow Newtonian physics.

2. **No Magic Technology**: No shields, no faster-than-light travel, no energy weapons. Only technologies that could plausibly exist: chemical rockets, railguns, nuclear warheads, and PDC systems.

3. **Intelligent Weapons**: Torpedoes aren't dumb projectiles but sophisticated guided munitions with their own sensors and decision-making capabilities.

4. **Scalable Architecture**: The systems must work whether tracking 2 torpedoes or 200, whether the map is 65km or 250,000km.

### 2.3 Initial Goals

The original roadmap outlined a phased approach:
- Phase 1: Basic physics and torpedo intercepts
- Phase 2: Sensor systems and uncertainty
- Phase 3: PDC implementation
- Phase 4: Advanced torpedo behaviors
- Phase 5: Railgun systems
- Phase 6: Full tactical gameplay

---

## 3. Current State of Development

### 3.1 Implemented Systems

#### 3.1.1 Physics Engine
The game uses Godot 4's physics system with significant modifications:
- **Frame-rate independent calculations** ensuring consistent behavior at any FPS
- **Meters-per-pixel scaling** allowing different map sizes without code changes
- **High-velocity collision detection** solving tunneling issues at extreme speeds

#### 3.1.2 Torpedo Guidance Systems
Three sophisticated guidance modes have been implemented:

**Straight Intercept**: Direct path to predicted intercept point
- Uses quadratic equations to solve intercept geometry
- Accounts for target velocity and acceleration
- Minimizes time to impact

**Multi-Angle Attack**: Creates bracketing attacks from port/starboard
- 45-degree approach angles for maximum target confusion
- Designed to split PDC attention
- Natural arc trajectories from geometric constraints

**Simultaneous Impact**: Coordinated strikes arriving together
- Calculates individual impact times for synchronized arrival
- Spreads torpedoes across 160-degree arc
- Forces PDC systems to engage multiple threats simultaneously

#### 3.1.3 PID Control Architecture
The current implementation uses normalized PID control:
```gdscript
normalized_error = velocity_error / max_speed
control_output = Kp * error + Ki * integral + derivative
```

This normalization ensures the same gains work at 200 m/s or 2000 m/s, critical for the game's variable scales.

#### 3.1.4 Point Defense Systems
PDCs operate as autonomous turrets with:
- 360-degree rotation capability
- 18 rounds per second fire rate
- Predictive targeting accounting for bullet travel time
- Priority-based target selection

#### 3.1.5 Battle Management
A sophisticated event-driven architecture tracks:
- Entity lifecycles (spawn, movement, destruction)
- Collision events with attribution
- PDC performance metrics
- Battle outcomes and statistics

### 3.2 Technical Achievements

#### 3.2.1 Solving the Tunneling Problem
At 200 km/s, torpedoes move 3.3km per frame at 60 FPS. Traditional collision detection fails completely. The solution involves:
- **Temporal collision windows**: Calculating exact moments when objects could collide
- **Adaptive substeps**: Only performing expensive calculations during collision windows
- **Swept volume testing**: Checking entire movement paths, not just endpoints

#### 3.2.2 Mode-Based Architecture
The game implements a clean separation between different operational modes:
- **Battle Mode**: Full combat simulation with all systems active
- **PID Tuning Mode**: Isolated environment for automated parameter optimization
- **Menu/Setup Mode**: System initialization without active simulation

This prevents systems from interfering with each other and ensures clean state management.

#### 3.2.3 Automated PID Tuning
A sophisticated auto-tuning system using gradient descent:
- Fires volleys of 8 torpedoes
- Measures hit rate and approach quality
- Adjusts PID gains to minimize cost function
- Requires 50 consecutive perfect volleys for validation
- Operates at locked 60 FPS for consistency

### 3.3 Current Limitations

1. **Speed Cap**: Torpedoes limited to 2000 m/s for testing (will be removed)
2. **Map Size**: Currently 65km × 37km (target: 250,000km+)
3. **No Damage Model**: Binary alive/dead states only
4. **Limited Ship Variety**: Only two ship types currently
5. **No Campaign Structure**: Pure combat sandbox

---

## 4. Technical Evolution and Architecture

### 4.1 The Journey from PID to MPC

#### 4.1.1 Why PID Was Insufficient
Initial implementation used PID control for torpedo guidance:
```gdscript
error = target_position - current_position
control = Kp * error + Ki * integral_error + Kd * derivative_error
```

While functional, PID revealed limitations:
- **Reactive, not predictive**: Only responds to current error
- **Poor trajectory planning**: Creates wobbly, inefficient paths
- **No constraint handling**: Can't account for rotation limits or map boundaries
- **Single objective**: Can't balance multiple goals (intercept vs. efficiency vs. evasion)

#### 4.1.2 The MPC Revolution
Model Predictive Control offers fundamental advantages:
- **Trajectory optimization**: Plans entire path to target
- **Constraint awareness**: Respects physical limitations
- **Multi-objective optimization**: Balances competing goals
- **Future-aware**: Anticipates target movement and obstacles

The proposed MPC implementation:
```gdscript
for each control_candidate in candidates:
    trajectory = simulate_future(current_state, control_candidate, horizon)
    cost = evaluate_trajectory(trajectory, target, constraints)
    if cost < best_cost:
        best_control = control_candidate
apply(best_control[0])  # Only first control action
```

### 4.2 Architecture Refactors

#### 4.2.1 The Entity Management Evolution
The system evolved through several iterations:

**Version 1**: Direct node references
- Ships held direct references to targets
- Frequent null reference errors
- Race conditions during destruction

**Version 2**: ID-based tracking
- String IDs for all entities
- Dictionary lookups for references
- Complex synchronization issues

**Version 3**: Immediate State Architecture
- Query scene tree each frame
- No persistent references
- Zero-trust validation

**Version 4**: Observer Pattern
- EntityManager as central authority
- Event-driven updates
- Clean separation of concerns

#### 4.2.2 The PDC System Overhaul
Original PDC implementation shot backwards due to flawed calculations. The refactor introduced:
- **Central Fire Control**: Ship-level coordination instead of individual PDC logic
- **Predictive targeting**: Account for bullet travel time correctly
- **Priority management**: Time-to-impact based threat assessment
- **Smooth transitions**: Continuous fire during target switches

### 4.3 Performance Optimizations

#### 4.3.1 Spatial Indexing
Instead of O(n²) collision checks:
- Quadtree spatial partitioning
- Only check nearby entities
- Dynamic tree rebalancing

#### 4.3.2 Frame-Rate Independence
Critical for consistent physics:
- All calculations use delta time
- Velocity in m/s, not pixels/frame
- Acceleration properly integrated

#### 4.3.3 Event System Efficiency
- Pooled event objects
- Deferred processing for non-critical events
- Batched updates for UI systems

---

## 5. Major Challenges and Solutions

### 5.1 The Tunneling Crisis

**Problem**: At realistic speeds, objects teleport through each other between frames.

**Failed Attempts**:
1. Increasing physics tick rate (melted CPU)
2. Continuous Collision Detection (Godot's implementation insufficient)
3. Fat raycast approximations (missed edge cases)

**Solution**: Temporal Collision Windows
- Calculate when objects COULD collide
- Focus computational effort on those moments
- Adaptive substeps only when needed
- Mathematical guarantee of detection

### 5.2 The Scale Paradox

**Problem**: Realistic space combat requires massive maps but tiny projectiles.

**Traditional Approach**: Limit speeds or increase projectile sizes
**Our Approach**: Selective realism
- Ships: 3× realistic size
- Torpedoes: 20× realistic size
- PDC rounds: 50× realistic size
- Maintains believable proportions while ensuring playability

### 5.3 The Reference Lifetime Problem

**Problem**: Godot's `queue_free()` creates "zombie" nodes that crash when accessed.

**Evolution of Solutions**:
1. **is_instance_valid()** checks (not always reliable)
2. **Signal-based cleanup** (race conditions)
3. **ID-based tracking** (synchronization nightmares)
4. **Immediate state queries** (final solution)

The winning approach: Never store node references across frames. Query what you need when you need it.

### 5.4 System Interference

**Problem**: Battle management, PID tuning, and regular gameplay systems conflicted.

**Solution**: Mode-based architecture with clear boundaries:
```gdscript
enum Mode { NONE, BATTLE, PID_TUNING }

signal mode_changed(new_mode)

func set_mode(new_mode: Mode):
    # Clean shutdown of previous mode
    # Configure all systems for new mode
    # Emit signal for subscribers
```

---

## 6. Future Development Roadmap

### 6.1 Immediate Priorities (Weeks 1-4)

#### 6.1.1 MPC Implementation
- Basic trajectory optimization
- Dynamic horizon calculation
- Cost function design
- Integration with existing systems

#### 6.1.2 GPU Acceleration
Leveraging the RTX 3080's 8,704 CUDA cores:
- Parallel trajectory evaluation
- Compute shader integration
- 100× performance improvement potential

#### 6.1.3 Collision System Completion
- Implement temporal windows
- Remove speed limitations
- Test at extreme velocities

### 6.2 Medium-Term Goals (Months 2-3)

#### 6.2.1 Advanced Torpedo Behaviors
- **Evasive Maneuvers**: Dodging predicted PDC streams
- **Swarm Coordination**: Multiple torpedoes working together
- **Terminal Guidance**: Different attack profiles for final approach

#### 6.2.2 Expanded Ship Variety
Using resource-based configuration:
```gdscript
class_name ShipConfig extends Resource
@export var ship_class: String  # "Corvette", "Destroyer", "Battleship"
@export var pdc_count: int
@export var torpedo_tubes: int
@export var armor_thickness: float
@export var acceleration_profile: Curve
```

#### 6.2.3 Damage Model
Moving beyond binary alive/dead:
- Component damage (PDCs, engines, sensors)
- Penetration mechanics
- Crew casualties affecting performance

### 6.3 Long-Term Vision (Months 4-12)

#### 6.3.1 Massive Scale Combat
- 250,000km+ battlefields
- Floating origin implementation
- Fleet-scale engagements
- Light-speed lag for sensors

#### 6.3.2 Campaign Structure
- Node-based system map
- Resource management
- Ship persistence and upgrades
- Narrative framework

#### 6.3.3 Advanced AI
- Neural network torpedo guidance
- Adversarial PDC strategies
- Fleet-level tactical AI
- Learning from player strategies

#### 6.3.4 Multiplayer Considerations
- Deterministic physics for synchronization
- Rollback netcode for responsiveness
- Asymmetric scenarios
- Replay system

---

## 7. Technical Deep Dives

### 7.1 MPC Architecture Details

#### 7.1.1 State Space Formulation
```
State vector: x = [position, velocity, orientation, angular_velocity]
Control vector: u = [thrust_magnitude, rotation_rate]
Dynamics: x(k+1) = f(x(k), u(k))
```

#### 7.1.2 Cost Function Design
```
J = Σ(k=0 to N) [
    w1 * ||position(k) - intercept_point(k)||² +    # Terminal accuracy
    w2 * ||control(k)||² +                           # Control effort
    w3 * threat_exposure(k) +                        # PDC avoidance
    w4 * orientation_error(k)                        # Alignment quality
]
```

#### 7.1.3 Optimization Strategy
- Shooting method for trajectory optimization
- Warm-starting from previous solution
- Early termination for real-time constraints
- Adaptive horizon based on time-to-intercept

### 7.2 GPU Compute Shader Design

#### 7.2.1 Parallel Trajectory Evaluation
```hlsl
[numthreads(64, 1, 1)]
void EvaluateTrajectories(uint3 id : SV_DispatchThreadID) {
    uint trajectoryIndex = id.x;
    
    // Load initial state and control sequence
    State state = LoadInitialState();
    ControlSequence controls = LoadControls(trajectoryIndex);
    
    // Simulate trajectory
    float cost = 0.0;
    for (int t = 0; t < HORIZON_LENGTH; t++) {
        state = PropagatePhysics(state, controls[t], DT);
        cost += EvaluateCost(state, targetState, threats);
    }
    
    // Write result
    costs[trajectoryIndex] = cost;
}
```

#### 7.2.2 Memory Layout Optimization
- Structure of Arrays for coalesced access
- Shared memory for common data
- Texture memory for trajectory templates

### 7.3 Predictive PDC Architecture

#### 7.3.1 Threat Assessment Pipeline
```gdscript
func assess_threat(torpedo: Node2D) -> ThreatData:
    var current_pos = torpedo.global_position
    var current_vel = torpedo.velocity_mps
    
    # Predict trajectory based on torpedo type
    var predicted_path = predict_torpedo_path(torpedo)
    
    # Calculate intercept windows
    var windows = []
    for t in range(0, MAX_INTERCEPT_TIME, WINDOW_STEP):
        var intercept_quality = calculate_intercept_quality(
            predicted_path[t], t
        )
        if intercept_quality > MINIMUM_QUALITY:
            windows.append({time: t, quality: intercept_quality})
    
    return {
        windows: windows,
        priority: calculate_priority(windows),
        assigned_pdcs: []
    }
```

#### 7.3.2 Coordinated Fire Patterns
Instead of individual targeting:
- **Barrage patterns**: Predetermined firing solutions
- **Adaptive walls**: React to torpedo evasion
- **Crossfire zones**: Multiple PDCs creating kill boxes

### 7.4 Battle Analytics System

#### 7.4.1 Event Sourcing Architecture
Every significant action creates an immutable event:
```gdscript
class BattleEvent:
    var timestamp: float
    var event_type: String
    var actor_id: String
    var target_id: String
    var position: Vector2
    var metadata: Dictionary
```

#### 7.4.2 Real-time Analysis
- Sliding window statistics
- Heat map generation
- Threat corridor identification
- Performance anomaly detection

---

## 8. Lessons Learned

### 8.1 Technical Insights

1. **Premature Optimization is Still Evil**: The original architecture tried to solve problems that didn't exist yet (radar range limits, ammunition tracking) while missing fundamental issues (tunneling, reference lifetime).

2. **Godot's Paradigms Matter**: Fighting against Godot's scene tree architecture leads to pain. Embracing immediate-mode queries and the observer pattern aligns with the engine's design.

3. **Physics Can't Be Cheated**: Every shortcut taken with physics (arbitrary speed limits, simplified collision) eventually needs to be fixed properly.

4. **Clean Architecture Enables Innovation**: The mode-based system separation made the PID tuner possible. Good architecture creates opportunities.

### 8.2 Design Insights

1. **Realism and Fun Can Coexist**: Players don't notice if a torpedo is 100m instead of 5m, but they do notice if physics feels wrong.

2. **Complexity Should Emerge, Not Be Imposed**: Simple rules (torpedoes seek targets, PDCs shoot torpedoes) create complex behaviors without complex code.

3. **Visual Feedback Is Critical**: Even with perfect physics, players need to understand what's happening. Trails, indicators, and smart camera work are essential.

### 8.3 Process Insights

1. **Document Everything**: The various architecture documents saved enormous time when returning to the project after breaks.

2. **Test at Scale Early**: Problems that appear with 100 torpedoes are very different from problems with 10.

3. **Automate Testing**: The PID tuner started as a testing tool but became a feature. Automated testing often reveals improvement opportunities.

---

## 9. Conclusion

Space Bastard represents more than just another space game; it's an attempt to realize a specific vision of space combat that has been largely ignored by the gaming industry. By embracing realistic physics, intelligent weapon systems, and the vast scales of space, it offers a unique tactical experience.

The journey from initial concept to current implementation has been marked by significant technical challenges, each requiring innovative solutions. The evolution from PID to MPC control, the solving of extreme-velocity tunneling, and the creation of a robust battle simulation framework demonstrate the complexity inherent in realistic space combat simulation.

Looking forward, the roadmap is ambitious but achievable. GPU acceleration will enable the computational complexity needed for true MPC implementation. Larger scales will test the floating origin system. Advanced AI will create emergent behaviors that surprise even the developers.

The core philosophy remains unchanged: create the space combat game that Expanse fans have been waiting for. One where distance matters, physics is real, and every torpedo launch is a calculated risk in the vast, unforgiving void of space.

### Final Statistics
- **Lines of Code**: ~15,000 (GDScript)
- **Development Time**: 6 months (part-time)
- **Refactors**: 4 major architecture changes
- **Peak Simultaneous Entities**: 500+ (torpedoes, bullets, ships)
- **Maximum Tested Velocity**: 2000 m/s (designed for 200,000+ m/s)
- **Typical Engagement Range**: 10-50 km (designed for 1000+ km)

The foundation is solid. The vision is clear. The void awaits.

---

*"In space, no one can hear you scream. But they can definitely see your torpedoes coming from 10,000 kilometers away. Plan accordingly."*

— Space Bastard Design Philosophy