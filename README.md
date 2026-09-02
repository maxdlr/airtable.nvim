# airtable.nvim

Browse and view Airtable records ("tickets") from Neovim via Telescope. Proof of concept:
records are listed through a configurable set of filters (default: "assigned to me") and
opened in a read-only markdown buffer showing the title and description fields.

## Requirements

- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) (HTTP client)
- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim)

## Installation

Using `vim.pack` (Neovim's built-in plugin manager):

```lua
vim.pack.add({
  'nvim-lua/plenary.nvim',
  'nvim-telescope/telescope.nvim',
  'you/airtable.nvim', -- or a local path while developing
})
```

## Setup

The Airtable API key is **never** stored in your config — it's read from an environment
variable at runtime.

```bash
# ~/.zshrc, ~/.bashrc, etc. Never commit this value.
export AIRTABLE_API_KEY="pat_..."
```

```lua
require('airtable').setup({
  api_key_env = 'AIRTABLE_API_KEY', -- name of the env var, not the key itself
  base_id = 'appXXXXXXXXXXXXXX',
  table_name = 'Tickets',
  fields = {
    title = 'Name',
    description = 'Description',
  },
  filters = {
    { name = 'Assigned to me', formula = "{Assignee} = 'Your Name'" },
    { name = 'Open bugs', formula = "AND({Status} != 'Done', {Type} = 'Bug')" },
  },
  default_filter = 'Assigned to me',
})
```

Filters are plain Lua table entries — add, edit, or remove them directly in your config.
Each filter needs a `name` (shown in the picker/command) and a `formula`
([Airtable formula syntax](https://support.airtable.com/docs/formula-field-reference)).

## Usage

```vim
:Airtable                     " opens the picker using the default filter
:Airtable Open bugs           " opens the picker using a named filter
```

Selecting a record opens a read-only scratch buffer rendering its title and description as
markdown.

## Scope of this POC

- Only the title and description fields are rendered.
- The record buffer is read-only — editing/syncing back to Airtable is not implemented.
- No caching: every invocation re-fetches from the Airtable API.
