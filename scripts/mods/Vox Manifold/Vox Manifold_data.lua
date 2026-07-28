local mod = get_mod("Vox Manifold")

return {
	name = "Vox Manifold",
	description = mod:localize("mod_description"),
	is_togglable = false,
	options = {
		widgets = {
			{
				setting_id    = "vm_debug",
				type          = "checkbox",
				default_value = false,
				tooltip       = "vm_debug_tooltip",
			},
		},
	},
}
