# airtable.nvim

Browse and view Airtable records from Neovim via Telescope. Records are listed through
one or more configurable **pickers** (named views with their own filters, sort order, and
result line layout) and opened in a read-only markdown buffer.

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

  -- Arbitrary named fields rendered in the record buffer. `title` (if present) becomes
  -- the H1 heading; every other key becomes its own "## <Key>" section. Add as many
  -- as you want — any Airtable field name works.
  buffer = {
    fields = {
      title = 'Name',
      description = 'Description',
    },
  },

  -- Named views. Each picker has its own filters, sort order, and result line layout.
  pickers = {
    {
      name = 'Assigned to me',
      filters = {
        { field = 'Assignee', value = 'Your Name', contains = true },
      },
      sort = { field = 'Priority', order = 'asc' },
      result_line = {
        { field = 'Name', hl = 'TelescopeResultsIdentifier' },
        { field = 'Status', hl = 'Comment' },
      },
    },
    {
      name = 'Open bugs',
      filters = {
        { field = 'Assignee', value = 'Your Name' },
        { field = 'Status', value = { 'To do', 'In progress' } }, -- OR: any of these
        { field = 'Type', value = 'Bug' },
      },
      result_line = {
        { field = 'Name', hl = 'TelescopeResultsIdentifier' },
        { field = 'Status', hl = 'Comment' },
      },
    },
  },

  default_filter = 'Assigned to me', -- picker opened by `:Airtable` with no argument
})
```

### `pickers[]`

Each entry is a named view:

- `name` *(required)* — shown in the picker title and used to select it via `:Airtable <name>`
  or `require('airtable').open('<name>')`.
- `filters` *(optional)* — a list of conditions, combined with **AND**. Omit entirely to list
  all records. Each condition is `{ field = '<Airtable field name>', value = ... }`:
  - `value` as a plain string/number — exact match (`{field} = 'value'`).
  - `value` as a list of strings — matches **any** of them, i.e. OR within that field
    (`{ field = 'Status', value = { 'To do', 'In progress' } }`).
  - `contains = true` — for fields that hold **multiple values** under the hood (linked
    records, multi-select, collaborator fields like a typical `Assignee`), where exact `=`
    can't match. Builds `FIND(value, ARRAYJOIN(field)) > 0` instead
    (`{ field = 'Assignee', value = 'Your Name', contains = true }`).
- `sort` *(optional)* — `{ field = '<Airtable field name>', order = 'asc'|'desc' }`. Maps
  directly to Airtable's `sort[]` API parameter.
- `result_line` *(required)* — ordered list of `{ field, hl }` sections shown left to right
  in the picker, separated by " │ ". A record missing a given field shows "—" instead of
  breaking the layout.

Every field name referenced anywhere (`buffer.fields`, `pickers[].filters[].field`,
`pickers[].sort.field`, `pickers[].result_line[].field`) must match your Airtable base's
actual field names exactly (case-sensitive) — these vary by team/base, so there is no
universal default that works everywhere.

## Usage

```vim
:Airtable                     " opens the picker named in `default_filter`
:Airtable Open bugs           " opens the picker named "Open bugs"
```

Selecting a record opens a read-only scratch buffer rendering `buffer.fields` as markdown.

### Keymapping individual pickers

Each picker can be bound to its own keymap by calling `require('airtable').open(name)`
directly instead of going through the `:Airtable` command:

```lua
vim.keymap.set('n', '<leader>jj', function() require('airtable').open() end, { desc = 'Airtable: default' })
vim.keymap.set('n', '<leader>jb', function() require('airtable').open 'Open bugs' end, { desc = 'Airtable: open bugs' })
```

## Scope of this POC

- The record buffer is read-only — editing/syncing back to Airtable is not implemented.
- No caching: every invocation re-fetches from the Airtable API.
- `buffer.fields` section order (beyond `title`) is alphabetical by key name, not
  configuration order — Lua tables with string keys have no inherent order.
