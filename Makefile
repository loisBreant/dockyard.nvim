NVIM ?= nvim
LUALS ?= lua-language-server

.PHONY: test typecheck

test:
	$(NVIM) --headless --clean -l tests/run.lua

typecheck:
	VIMRUNTIME="$$($(NVIM) --clean --headless -c 'lua io.stdout:write(vim.env.VIMRUNTIME)' -c qa)" \
		$(LUALS) --check=. --checklevel=Warning --configpath=.luarc.json | tee /dev/stderr | grep -q "no problems found"
