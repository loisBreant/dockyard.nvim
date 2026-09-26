describe("modules", function()
	it("setup() runs and registers the commands", function()
		require("dockyard").setup({})
		for _, cmd in ipairs({ "Dockyard", "DockyardFloat", "DockyardRun", "DockyardService", "DockyardPick", "DockyardFiles", "DockyardLogs" }) do
			eq(2, vim.fn.exists(":" .. cmd), cmd)
		end
	end)

	it("every dockyard module loads", function()
		local root = vim.api.nvim_get_runtime_file("lua/dockyard/init.lua", false)[1]:gsub("/init%.lua$", "")
		for _, file in ipairs(vim.fn.globpath(root, "**/*.lua", false, true)) do
			local mod = file:gsub("^.*/lua/", ""):gsub("%.lua$", ""):gsub("/init$", ""):gsub("/", ".")
			local ok, err = pcall(require, mod)
			truthy(ok, mod .. ": " .. tostring(err))
		end
	end)
end)
