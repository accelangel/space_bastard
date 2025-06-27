extends Camera2D

@export var zoomSpeed : float = 10

var zoomTarget :Vector2


func _ready():
	zoomTarget = zoom
	pass

func _process(delta):
	Zoom(delta)
	Pan()
	ClickAndDrag()

func Zoom(delta):
	if Input.is_action_just_pressed("camera_zoom_in"):
		zoomTarget *= 1.1
	
	if Input.is_action_just_pressed("camera_zoom_out"):
		zoomTarget *= 0.9
		
	zoom = zoom.slerp(zoomTarget, zoomSpeed * delta) # Makes the zoom choppy and more sluuuurpy aw bby
	pass

func Pan():
	if Input.is_action_pressed("camera_move_right"):
		position.x += 1
	if Input.is_action_pressed("camera_move_left"):
		position.x -= 1
	if Input.is_action_pressed("camera_move_up"):
		position.y -= 1
	if Input.is_action_pressed("camera_move_down"):
		position.y += 1
	
	pass

func ClickAndDrag():
	pass
