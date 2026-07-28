return {
	run = function()
		fassert(rawget(_G, "new_mod"), "`Vox Manifold` encountered an error loading the Darktide Mod Framework.")

		new_mod("Vox Manifold", {
			mod_script       = "Vox Manifold/scripts/mods/Vox Manifold/Vox Manifold",
			mod_data         = "Vox Manifold/scripts/mods/Vox Manifold/Vox Manifold_data",
			mod_localization = "Vox Manifold/scripts/mods/Vox Manifold/Vox Manifold_localization",
		})
	end,
	load_after = {},
	require = {},
	version = "1.0.1",
	packages = {},
}
