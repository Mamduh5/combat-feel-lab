extends Node3D

const IDLE_ANIMATION := &"Idle_A"
const HIT_REACTION_ANIMATION := &"Hit_A"
const ANIMATION_SOURCE := preload("res://assets/third_party/KayKit_Character_Animations_1.1/Animations/gltf/Rig_Medium/Rig_Medium_General.glb")

@export var max_health: int = 100
@export_range(0.06, 0.10, 0.01) var hit_flash_duration: float = 0.08

@onready var health_label: Label3D = $Label3D
@onready var target_character: Node3D = $VisualRoot/TargetCharacter
@onready var target_animation_player: AnimationPlayer = $VisualRoot/TargetAnimationPlayer

var current_health: int
var _flash_material: StandardMaterial3D
var _flash_meshes: Array[MeshInstance3D] = []
var _original_material_overrides: Dictionary = {}
var _flash_generation := 0


func _ready() -> void:
	current_health = max_health
	_update_health_label()
	_setup_target_animations()
	_setup_hit_flash()
	target_animation_player.animation_finished.connect(_on_target_animation_finished)
	_play_idle()


func take_damage(amount: int) -> bool:
	if amount <= 0 or current_health <= 0:
		return false

	var previous_health := current_health
	current_health = clampi(current_health - amount, 0, max_health)
	if current_health == previous_health:
		return false

	_update_health_label()
	target_animation_player.play(HIT_REACTION_ANIMATION)
	_trigger_hit_flash()
	return true


func _setup_target_animations() -> void:
	var animation_source := ANIMATION_SOURCE.instantiate()
	var source_player := animation_source.find_child("AnimationPlayer", true, false) as AnimationPlayer
	var source_library := source_player.get_animation_library(&"")
	var target_library := source_library.duplicate(true) as AnimationLibrary
	target_animation_player.add_animation_library(&"", target_library)
	animation_source.free()


func _setup_hit_flash() -> void:
	_flash_material = StandardMaterial3D.new()
	_flash_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_flash_material.albedo_color = Color(1.0, 0.9, 0.65)
	_flash_material.emission_enabled = true
	_flash_material.emission = Color(1.0, 0.65, 0.25)
	_flash_material.emission_energy_multiplier = 2.0

	for child in target_character.find_children("*", "MeshInstance3D", true, false):
		var mesh := child as MeshInstance3D
		_flash_meshes.append(mesh)
		_original_material_overrides[mesh] = mesh.material_override


func _trigger_hit_flash() -> void:
	_flash_generation += 1
	var generation := _flash_generation
	for mesh in _flash_meshes:
		mesh.material_override = _flash_material

	await get_tree().create_timer(hit_flash_duration, true, false, true).timeout
	if generation != _flash_generation:
		return
	for mesh in _flash_meshes:
		if is_instance_valid(mesh):
			mesh.material_override = _original_material_overrides[mesh]


func _play_idle() -> void:
	target_animation_player.play(IDLE_ANIMATION)


func _on_target_animation_finished(animation_name: StringName) -> void:
	if animation_name == HIT_REACTION_ANIMATION or animation_name == IDLE_ANIMATION:
		_play_idle()


func _update_health_label() -> void:
	health_label.text = "%d HP" % current_health
