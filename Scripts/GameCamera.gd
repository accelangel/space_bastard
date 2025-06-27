extends Camera2D

func _ready():
	pass

func _process(delta):
	Zoom()
	Pan()
	ClickAndDrag()

func Zoom():
	if Input.is_action_just_pressed("camera_zoom_in"):
		zoom = zoom * 1.1
	
	if Input.is_action_just_pressed("camera_zoom_out"):
		zoom = zoom * 0.9
	pass

func Pan():
	pass

func ClickAndDrag():
	pass
