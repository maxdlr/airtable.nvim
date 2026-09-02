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

The Airtable personal access token is **never** stored in your config — it's read from an
environment variable at runtime.

```bash
# ~/.zshrc, ~/.bashrc, etc. Never commit this value.
export AIRTABLE_TOKEN="pat_..."
```

```lua
require('airtable').setup({
  token_env = 'AIRTABLE_TOKEN', -- name of the env var, not the token itself
  base_id = 'appXXXXXXXXXXXXXX',
  table_name = 'Tickets',
  fields = {
    title = 'Name',
    description = 'Description',
  },
  -- Sections shown in the picker's result line, left to right, separated by " │ ".
  -- Defaults to just `fields.title`. Add more fields to show extra context
  -- (status, assignee, etc.) — any Airtable field name works, and a missing
  -- value on a given record renders as "—" instead of breaking the layout.
  display = {
    { field = 'Name', hl = 'TelescopeResultsIdentifier' },
    { field = 'Status', hl = 'Comment' },
    { field = 'Assignee', hl = 'Comment' },
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

Every field name (`fields.title`, `fields.description`, `display[].field`, and any field
referenced in a filter's `formula`) must match your Airtable base's actual field names exactly
(case-sensitive) — these vary by team/base, so there is no universal default that works
everywhere. If the picker shows record ids instead of titles, double check `fields.title`
against the real column name in Airtable.

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
