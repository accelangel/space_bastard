# Camera System Technical Documentation

## Table of Contents
1. [System Overview](#system-overview)
2. [Architecture](#architecture)
3. [Core Components](#core-components)
   - [GameCamera (Main Camera)](#gamecamera-main-camera)
   - [PiPCamera (Picture-in-Picture)](#pipcamera-picture-in-picture)
   - [GridOverlay](#gridoverlay)
   - [GridSizeLabel](#gridsizelabel)
4. [Implementation Details](#implementation-details)
5. [Input System](#input-system)
6. [Rendering Pipeline](#rendering-pipeline)
7. [Configuration Reference](#configuration-reference)
8. [Performance Optimizations](#performance-optimizations)
9. [Known Issues & Solutions](#known-issues--solutions)
10. [Future Enhancements](#future-enhancements)

## System Overview

The Space Combat game implements a sophisticated multi-camera system designed to provide players with comprehensive battlefield awareness. The system consists of a primary game camera with advanced controls, dual Picture-in-Picture (PiP) views for tracking specific ships, and a dynamic grid overlay system for spatial reference.

### Key Features
- **Advanced Main Camera**: Smooth zoom, multiple navigation modes, ship tracking
- **Dual PiP Views**: Independent mini-cameras for player and enemy ships
- **Dynamic Grid System**: Adaptive world-space grid that scales with zoom
- **Unified Input Handling**: Conflict-free controls across all cameras

## Architecture

```
WorldRoot (Node2D)
├── ColorRect (Background)
├── GridCanvasLayer (CanvasLayer)
│   └── GridOverlay (Node2D)
├── GameCamera (Camera2D)
├── Ships & Game Objects
└── UILayer (CanvasLayer)
    ├── PlayerPiP (SubViewportContainer)
    │   └── SubViewport
    │       └── Camera2D
    ├── EnemyPiP (SubViewportContainer)
    │   └── SubViewport
    │       └── Camera2D
    └── GridSizeLabel (Control)
```

### Design Principles
1. **Separation of Concerns**: Each camera system handles its own viewport
2. **Non-Intrusive UI**: PiP cameras and grid don't interfere with gameplay
3. **Performance First**: Only render what's visible
4. **Intuitive Controls**: Industry-standard camera controls

## Core Components

### GameCamera (Main Camera)

**File**: `Scripts/Systems/GameCamera.gd`  
**Node Type**: `Camera2D`  
**Group**: `game_camera`

#### Capabilities

##### 1. Zoom System
- **Smooth Interpolation**: Exponential zoom with configurable speed (default: 11x)
- **Zoom-to-Cursor**: Maintains world position under cursor during zoom
- **Dynamic Range**: Auto-calculated minimum zoom shows entire map
- **Limits**: 0.01397 (full map) to 5.0 (maximum zoom)

##### 2. Navigation Modes

**Free Camera Mode**
- WASD/Arrow keys for panning
- Speed scales with zoom level
- No restrictions on movement

**Drag Panning**
- Middle mouse button to drag
- 1:1 movement with mouse
- Intuitive grab-and-move feel

**Ship Following**
- Left-click any ship/torpedo to follow
- Maintains smooth tracking
- Relative offset support

##### 3. Advanced Following System
```gdscript
# Following states
following_ship: Node2D = null
follow_offset: Vector2 = Vector2.ZERO
relative_pan_offset: Vector2 = Vector2.ZERO

# Features
- Automatic target validation
- Visual selection indicator (pulsing cyan circle)
- Relative panning while following (middle-drag)
- Escape key to exit follow mode
```

##### 4. Map Boundary System
The camera intelligently clamps to map boundaries, preventing views outside the game world:
```gdscript
const MAP_WIDTH: float = 131072.0
const MAP_HEIGHT: float = 73728.0

# Clamping formula accounts for zoom
camera_pos = Vector2(
    clamp(actual_pos.x, -MAP_WIDTH/2 + view_half_width, MAP_WIDTH/2 - view_half_width),
    clamp(actual_pos.y, -MAP_HEIGHT/2 + view_half_height, MAP_HEIGHT/2 - view_half_height)
)
```

### PiPCamera (Picture-in-Picture)

**File**: `Scripts/UI/PiPCamera.gd`  
**Node Type**: `SubViewportContainer`  
**Group**: `pip_cameras`

#### Design
Each PiP camera provides an independent view of a specific ship:
- **Player PiP**: Top-left corner (0, 0)
- **Enemy PiP**: Bottom-right corner (dynamic)

#### Features

##### 1. Independent Viewport
```gdscript
# Each PiP has its own rendering pipeline
SubViewportContainer
├── SubViewport (size: 200x200)
│   └── Camera2D (follows target ship)
├── BorderPanel (green outline)
└── LabelContainer (ship identifier)
```

##### 2. Zoom Control
- **Range**: 0.2x to 1.65x
- **Default**: 1.0x
- **Control**: Mouse wheel when cursor over PiP
- **Interpolation**: Smooth transition at 10x speed

##### 3. Visual Design
- 2px green border for visibility
- Dark background label showing ship type
- Transparent to game world (shares world_2d)
- Auto-repositions on window resize

##### 4. Performance
- Only updates when target exists
- Efficient viewport size (200x200)
- No grid rendering overhead

### GridOverlay

**File**: `Scripts/UI/GridOverlay.gd`  
**Node Type**: `Node2D`  
**Parent**: `GridCanvasLayer`

#### Adaptive Grid Algorithm

The grid system dynamically adjusts spacing based on zoom level to maintain consistent visual density:

```gdscript
func get_nice_number(value: float) -> float:
    # Rounds to nearest "nice" number for clean grid intervals
    var magnitude = pow(10, floor(log(value) / log(10)))
    var normalized = value / magnitude
    
    if normalized < 2.0: nice = 1.0      # 1, 10, 100, 1000...
    elif normalized < 4.0: nice = 2.0    # 2, 20, 200, 2000...
    elif normalized < 8.0: nice = 5.0    # 5, 50, 500, 5000...
    else: nice = 10.0                    # Back to 10x
    
    return nice * magnitude
```

#### Rendering System

##### 1. Index-Based Drawing
Instead of iterating through positions, the system calculates exact line indices:
```gdscript
var start_x_index = floor(world_left / grid_spacing_pixels) - 1
var end_x_index = ceil(world_right / grid_spacing_pixels) + 1

for i in range(start_x_index, end_x_index + 1):
    var x = i * grid_spacing_pixels
    # Draw line at x
```

##### 2. Visual Hierarchy
- **Major Lines**: Every 5th line, 2px width, full opacity
- **Minor Lines**: All others, 1px width, 50% opacity
- **Color**: Subtle gray (0.3, 0.3, 0.3, 0.5)

##### 3. Performance Features
- Only draws visible lines
- Skips rendering when spacing < 10 pixels
- Uses world coordinates for stability
- No coordinate transformation overhead

##### 4. Canvas Layer Integration
The grid exists on a separate CanvasLayer to:
- Follow the main viewport automatically
- Exclude from PiP camera rendering
- Maintain world-space alignment

### GridSizeLabel

**File**: `Scripts/UI/GridSizeLabel.gd`  
**Node Type**: `Control`  
**Parent**: `UILayer`

#### Label Pool System
Manages a pool of 20 reusable label containers for efficiency:
```gdscript
# Pre-created label pool
for i in range(max_labels):
    var container = PanelContainer.new()
    var label = Label.new()
    container.add_child(label)
    label_pool.append(container)
```

#### Smart Positioning
Labels appear at major grid intersections with intelligent filtering:
- Only at even-indexed major grid intersections
- Maximum 20 visible labels
- Fade effect near screen edges
- 5px offset from intersection point

#### Format Scaling
```gdscript
if meters < 1000:
    return "%d m" % int(meters)
elif meters < 10000:
    return "%.1f km" % (meters / 1000.0)
else:
    return "%d km" % int(meters / 1000.0)
```

## Implementation Details

### Scene Structure Requirements

1. **GridCanvasLayer Setup**
   ```
   GridCanvasLayer (CanvasLayer)
   - Layer: 1
   - Follow Viewport Enabled: ON
   - Follow Viewport Scale: 1.0
   ```

2. **PiP Camera Configuration**
   ```
   SubViewportContainer
   - Size: 200x200
   - Stretch: true
   - Mouse Filter: STOP
   ```

### Group Assignments
- GameCamera: `"game_camera"`
- PiP Cameras: `"pip_cameras"`
- Ships: `"player_ships"`, `"enemy_ships"`
- Torpedoes: `"torpedoes"`

### World Settings Integration
```gdscript
# From WorldSettings.gd
meters_per_pixel := 0.25
map_size_pixels := Vector2(131072, 73728)
map_size_meters := meters_per_pixel * map_size_pixels
```

## Input System

### Input Actions Required
```
camera_zoom_in: Mouse Wheel Up
camera_zoom_out: Mouse Wheel Down
camera_pan: Middle Mouse Button
camera_move_up: W, Up Arrow
camera_move_down: S, Down Arrow
camera_move_left: A, Left Arrow
camera_move_right: D, Right Arrow
select_ship: Left Mouse Button
ui_cancel: Escape
```

### Input Priority Resolution
1. Check if mouse is over any PiP camera
2. If yes, PiP handles zoom input
3. If no, main camera handles all input
4. Click-and-drag states maintained separately

## Rendering Pipeline

### Draw Order
1. **World Layer (0)**
   - Game objects, ships, projectiles
   - Background ColorRect

2. **Canvas Layer 1**
   - GridOverlay (follows viewport)

3. **UI Layer**
   - PiP cameras (SubViewports)
   - Grid size labels
   - Other UI elements

### Viewport Configuration
- **Main Viewport**: Full window size, renders everything
- **PiP SubViewports**: 200x200, share world_2d with main
- **Grid Exclusion**: CanvasLayer prevents grid in SubViewports

## Configuration Reference

### GameCamera Exports
```gdscript
@export var zoomSpeed: float = 11.0
@export var follow_smoothing: float = 12.0
```

### PiPCamera Exports
```gdscript
@export_enum("Player", "Enemy") var target_ship_type: String = "Player"
@export var min_zoom: float = 0.2
@export var max_zoom: float = 1.65
@export var zoom_speed: float = 10.0
@export var default_zoom: float = 1.0
@export var pip_size: Vector2 = Vector2(200, 200)
@export var margin: float = 0.0
```

### GridOverlay Exports
```gdscript
@export var grid_color: Color = Color(0.3, 0.3, 0.3, 0.5)
@export var label_color: Color = Color(0.5, 0.5, 0.5, 0.8)
@export var major_line_width: float = 2.0
@export var minor_line_width: float = 1.0
@export var target_spacing_pixels: float = 120.0
@export var show_minor_grid: bool = true
@export var minor_grid_divisions: int = 5
```

### GridSizeLabel Exports
```gdscript
@export var font_size: int = 12
@export var label_color: Color = Color(0.5, 0.5, 0.5, 0.6)
@export var background_color: Color = Color(0, 0, 0, 0.5)
@export var padding: int = 3
@export var max_labels: int = 20
```

## Performance Optimizations

### Grid Rendering
1. **Culling**: Only visible lines calculated and drawn
2. **Density Limit**: No rendering when grid spacing < 10 pixels
3. **Index-Based**: Direct calculation instead of iteration
4. **Caching**: Major line positions stored for label placement

### Camera Updates
1. **Interpolation**: Smooth transitions reduce per-frame calculations
2. **Dirty Checking**: Only update when values change
3. **Group Queries**: Cached group lookups for ships

### PiP Optimization
1. **Small Viewports**: 200x200 reduces rendering overhead
2. **Shared World**: No duplicate physics or game logic
3. **Conditional Updates**: Only process when target exists

### Label Management
1. **Object Pooling**: Reuse label containers
2. **Visibility Culling**: Hide off-screen labels
3. **Update Throttling**: Only on grid redraw

## Known Issues & Solutions

### Issue: Grid Disappears at Map Edges
**Cause**: Camera position exceeds coordinate limits  
**Solution**: Clamp camera position to match visual bounds

### Issue: PiP Shows Grid
**Cause**: Grid renders to world space  
**Solution**: Move grid to CanvasLayer with follow_viewport enabled

### Issue: Zoom Conflicts Between Cameras
**Cause**: Global input system processes all cameras  
**Solution**: Check mouse position before processing zoom

### Issue: Grid Performance at High Zoom
**Cause**: Too many lines being drawn  
**Solution**: Skip rendering when spacing < 10 pixels

## Future Enhancements

### Planned Features
1. **Configurable PiP Layout**: Allow corners, sides, or custom positions
2. **Multi-Target Following**: Follow formation center or multiple ships
3. **Smooth Follow Camera**: Predictive tracking with velocity
4. **Camera Presets**: Save/load camera positions and zoom
5. **Cinematic Mode**: Scripted camera movements for replays

### Potential Improvements
1. **Hexagonal Grid Option**: For games with hex-based movement
2. **Grid Rotation**: Align with ship orientation
3. **Distance Measurements**: Click-drag to measure
4. **Fog of War Integration**: Hide grid in unseen areas
5. **Performance Metrics**: Built-in camera system profiler
6. **Touch Control Support**: Mobile-friendly camera controls
7. **Split-Screen Mode**: Multiple main viewports
8. **Recording System**: Camera path recording for cinematics

## Debugging

### Common Debug Commands
```gdscript
# Print camera state
print("Camera pos: ", camera.global_position)
print("Camera zoom: ", camera.zoom)
print("Following: ", camera.following_ship != null)

# Grid debugging
print("Grid spacing: ", grid_overlay.current_grid_size_meters)
print("Visible lines: ", end_index - start_index)

# PiP debugging  
print("PiP target valid: ", is_instance_valid(target_ship))
print("PiP zoom: ", camera.zoom)
```

### Performance Monitoring
- Track `_draw()` calls per second for GridOverlay
- Monitor viewport sizes and counts
- Check input event propagation with `print_tree()`

---

*Last Updated: Space Combat Camera System v1.0*  
*Engine: Godot 4.3*