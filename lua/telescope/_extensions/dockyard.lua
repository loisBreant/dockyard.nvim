-- :Telescope dockyard

local ok, telescope = pcall(require, "telescope")
if not ok then
	error("dockyard: this extension requires nvim-telescope/telescope.nvim")
end

local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local previewers = require("telescope.previewers")
local conf = require("telescope.config").values
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")

local picker = require("dockyard.picker")

local function containers(opts, items)
	opts = opts or {}
	pickers
		.new(opts, {
			prompt_title = opts.all and "Containers (all)" or "Containers",
			finder = finders.new_table({
				results = items,
				entry_maker = function(c)
					return {
						value = c,
						display = picker.format(c),
						ordinal = table.concat({ c.name, c.image, c.status, c.ports or "", c.compose_project or "" }, " "),
					}
				end,
			}),
			sorter = conf.generic_sorter(opts),
			previewer = previewers.new_buffer_previewer({
				title = "docker inspect",
				define_preview = function(self, entry)
					local res = vim.system({ "docker", "inspect", entry.value.id }, { text = true }):wait()
					local lines = vim.split(res.stdout or "", "\n", { plain = true })
					vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
					vim.bo[self.state.bufnr].filetype = "json"
				end,
			}),
			attach_mappings = function(prompt_bufnr, map)
				local function with(fn)
					return function()
						local entry = action_state.get_selected_entry()
						actions.close(prompt_bufnr)
						if entry then
							fn(entry.value)
						end
					end
				end
				actions.select_default:replace(with(picker.choose_action))
				local direct = {
					["<C-l>"] = "logs",
					["<C-t>"] = "shell",
					["<C-f>"] = "files",
					["<C-o>"] = "open",
					["<C-s>"] = "toggle",
					["<C-r>"] = "restart",
				}
				for key, action in pairs(direct) do
					map({ "i", "n" }, key, with(function(c)
						picker.run(c, action)
					end))
				end
				map({ "i", "n" }, "<C-a>", function()
					actions.close(prompt_bufnr)
					require("dockyard.core.docker").list_containers(function(res)
						if res.ok then
							containers(vim.tbl_extend("force", opts, { all = true }), res.data or {})
						end
					end)
				end)
				return true
			end,
		})
		:find()
end

return telescope.register_extension({
	exports = {
		dockyard = function(opts)
			picker.list(function(items)
				containers(opts, items)
			end)
		end,
	},
})
