# airtable.nvim

Browse, filter, and preview Airtable records from Neovim — powered by Telescope.

Define one or more **pickers** (named views with their own filters, sort, and result
layout), open them with a single command or keymap, and view full records as read-only
markdown. Includes a live preview, comment browsing, and quick actions to open or copy a
record's Airtable URL.

## Requirements

- Neovim ≥ 0.10
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)
- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim)

## Installation

<details open>
<summary><code>vim.pack</code> (built-in, Neovim ≥ 0.12)</summary>

```lua
vim.pack.add({
  'https://github.com/nvim-lua/plenary.nvim',
  'https://github.com/nvim-telescope/telescope.nvim',
  'https://github.com/maxdlr/airtable.nvim',
})
```

</details>

<details>
<summary><a href="https://github.com/folke/lazy.nvim">lazy.nvim</a></summary>

```lua
{
  'you/airtable.nvim',
  dependencies = { 'nvim-lua/plenary.nvim', 'nvim-telescope/telescope.nvim' },
  opts = { --[[ see Configuration below ]] },
}
```

</details>

<details>
<summary><a href="https://github.com/wbthomason/packer.nvim">packer.nvim</a></summary>

```lua
use({
  'you/airtable.nvim',
  requires = { 'nvim-lua/plenary.nvim', 'nvim-telescope/telescope.nvim' },
  config = function() require('airtable').setup({ --[[ see Configuration below ]] }) end,
})
```

</details>

## Authentication

Your Airtable personal access token is **never** stored in config — it's read from an
environment variable at runtime.

```bash
# ~/.zshrc, ~/.bashrc, etc. — never commit this value.
export AIRTABLE_TOKEN="pat_..."
```

Generate a token at [airtable.com/create/tokens](https://airtable.com/create/tokens) with
the `data.records:read` scope, and grant it access to your base.

## Configuration

```lua
require('airtable').setup({
  token_env = 'AIRTABLE_TOKEN',   -- name of the env var holding your token (not the token itself)
  base_id = 'appXXXXXXXXXXXXXX',  -- your Airtable base id
  table_name = 'Tickets',         -- exact table name (or its "tbl..." id) in that base
  page_size = 100,                -- records fetched per API page (Airtable max: 100)

  buffer = {
    fields = {                    -- arbitrary fields rendered when a record is opened
      title = 'Title',            -- "title" is special: rendered as the H1 heading
      description = 'Description',-- any other key becomes its own "## <Key>" section
    },
  },

  pickers = {                     -- one or more named views, switch between them by name
    {
      name = 'Assigned to me',    -- shown in the picker title; used to select this view
      filters = {                 -- conditions combined with AND (omit to list everything)
        { field = 'Assignee', value = 'Your Name' }, -- matches even array-shaped fields
        { field = 'Type', value = 'Bug', only = true }, -- only=true: exact match instead
      },
      sort = { field = 'Priority', order = 'asc' }, -- optional; order: 'asc' or 'desc'
      result_line = {              -- columns shown per row, left to right
        { field = 'Title' },       -- hl omitted: defaults to an identifier color
        { field = 'Status', hl = '#FFA500' }, -- hl: a highlight group or hex color
      },
    },
  },

  default_filter = 'Assigned to me', -- picker opened by `:Airtable` with no argument
})
```

> Every field name above must match your Airtable base's actual column names exactly
> (case-sensitive) — there's no universal default, since this varies by base.

If you skip `pickers` entirely, `:Airtable` lists every record in `table_name` — no
filters required to get started.

### Record styling

Opening a record (and its Telescope preview) styles each `buffer.fields` entry based on
its key name, no configuration needed:

- Keys like `status`, `assignee`, `reviewer`, `type`, `priority`, or `label` render as a
  colored pill — the color is derived deterministically from the field's value, so the
  same value always gets the same color.
- Keys like `name`, `title`, or `id` render with heading-style emphasis.
- Everything else renders as plain text with a left border bar.

Colors adapt to your colorscheme and never break the render — if a color can't be
resolved for any reason, the plugin falls back to plain, unstyled text.

<details>
<summary><b>Advanced settings</b> (optional — click to expand)</summary>

#### `result_line_prefix`: conditional icons

Add a leading icon to a picker's result line based on a record's field value — useful for
status/priority/assignee-style visual markers. Evaluated locally against already-fetched
data (no extra requests). The first matching condition wins; no match means no icon.

```lua
pickers = {
  {
    name = 'Tickets',
    result_line = {
      { field = 'Title' },
      { field = 'Status' },
    },
    result_line_prefix = {
      -- { icon, condition } pairs, checked in order — condition uses the same shape as `filters`
      { '📝', { field = 'Status', value = 'In progress' } },
      { '▶️', { field = 'Status', value = 'To do' } },
      { '✅', { field = 'Status', value = 'Done', only = true } }, -- only=true still works here
      -- icon can also be a table to color it: { icon = '...', color = <hl group or hex> }
      { { icon = '󰲶', color = '#FFFFFF' }, { field = 'Status', value = 'Blocked' } },
    },
  },
},
```

</details>

## Usage

```vim
:Airtable                  " open the default picker
:Airtable Open bugs        " open a specific picker by name
```

Inside a record buffer, press `<CR>` for quick actions: open in browser, browse comments,
or copy the record's URL.

### Keymaps

```lua
vim.keymap.set('n', '<leader>aa', function() require('airtable').open() end, { desc = 'Airtable' })
vim.keymap.set('n', '<leader>ab', function() require('airtable').open('Open bugs') end, { desc = 'Airtable: open bugs' })
```

## Scope

- Read-only — this plugin does not write back to Airtable.
- No local caching — every command re-fetches from the API.
