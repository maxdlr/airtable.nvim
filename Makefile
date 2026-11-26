.PHONY: test

# Runs every tests/*_spec.lua headlessly. Override plenary's location with PLENARY_DIR.
test:
	nvim --headless --noplugin -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/ { minimal_init = 'tests/minimal_init.lua', sequential = true }"
