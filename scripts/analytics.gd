extends Node
# Stub: dedicated servers do not track analytics.
# WorldSim calls these methods; we satisfy the interface with safe defaults.

var _flags: Dictionary = {}

func release_flag_bool(name: String, default_value: bool = false) -> bool:
	return bool(_flags.get(name, default_value))


func admin_flag_float(_name: String, default_value: float = 0.0) -> float:
	return default_value


func record_activation_step(_step: String, _params: Dictionary = {}) -> void:
	pass


func event(_event_name: String, _params: Dictionary = {}) -> void:
	pass
