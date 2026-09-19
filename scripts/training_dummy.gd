extends Node3D

@export var max_health: int = 100

@onready var health_label: Label3D = $Label3D

var current_health: int


func _ready() -> void:
	current_health = max_health
	_update_health_label()


func take_damage(amount: int) -> void:
	current_health = clampi(current_health - amount, 0, max_health)
	_update_health_label()


func _update_health_label() -> void:
	health_label.text = "%d HP" % current_health
