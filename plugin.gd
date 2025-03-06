# plugin.gd
# This file is part of I, Voyager
# https://ivoyager.dev
# *****************************************************************************
# Copyright 2017-2025 Charlie Whitfield
# I, Voyager is a registered trademark of Charlie Whitfield in the US
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# *****************************************************************************
@tool
extends EditorPlugin

# Adds autoload singleton(s) as specified by config files
# 'res://addons/ivoyager_save/save.cfg' and 'res://ivoyager_override.cfg'.

const plugin_utils := preload("plugin_utils.gd")

var _config: ConfigFile # base config with overrides
var _autoloads := {}


func _enter_tree() -> void:
	
	# FIXME: Delay is a hack fix until fully decoupled from ivoyager_core
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame
	
	plugin_utils.print_plugin_name_and_version("ivoyager_save"," - https://ivoyager.dev")
	_config = plugin_utils.get_ivoyager_config("res://addons/ivoyager_save/save.cfg")
	if !_config:
		return
	_add_autoloads()


func _exit_tree() -> void:
	print("Removing I, Voyager - Save (plugin)")
	_config = null
	_remove_autoloads()


func _add_autoloads() -> void:
	for autoload_name in _config.get_section_keys("save_autoload"):
		var value: Variant = _config.get_value("save_autoload", autoload_name)
		if value: # could be null or "" to negate
			assert(typeof(value) == TYPE_STRING,
					"'%s' must specify a path as String" % autoload_name)
			_autoloads[autoload_name] = value
	for autoload_name: String in _autoloads:
		var path: String = _autoloads[autoload_name]
		add_autoload_singleton(autoload_name, path)


func _remove_autoloads() -> void:
	for autoload_name: String in _autoloads:
		remove_autoload_singleton(autoload_name)
	_autoloads.clear()
