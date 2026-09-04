<p align="center">
  <img width="100" height="83" alt="Airtable_idbbncOsuL_1" src="https://github.com/user-attachments/assets/2ef07cdc-5d24-429d-9a95-98ae3fe39812" />
  <p/>

<h1 align="center">airtable.nvim</h1>

Browse, filter, and preview Airtable records from Neovim.

Define one or more **pickers** (named views with their own filters, sort, and result
layout), open them with a single command or keymap, and view full records as markdown.
Includes a live preview, comment browsing, quick actions to open or copy a record's
Airtable URL, and optional safe editing of specific fields you explicitly configure.

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

Your Airtable personal access token is **never** stored in config, it's read from an
environment variable at runtime.

```bash
# ~/.zshrc, ~/.bashrc, etc. — never commit this value.
export AIRTABLE_TOKEN="pat..."
```

Generate a token at [airtable.com/create/tokens](https://airtable.com/create/tokens) with
the `data.records:read` scope, and grant it access to your base. If you configure
`buffer.editable` (see below), the token also needs `data.records:write`.

## Configuration

### Minimum config

All Airtable fields are custom, most of the time, so don't forget to rename them to match their exact names.
If you skip `pickers` entirely, `:Airtable` lists every record in `table_name`.

```lua
require('airtable').setup({
  token_env = 'AIRTABLE_TOKEN',   -- name of the env var holding your token (not the token itself)
  base_id = 'appXXXXXXXXXXXXXX',  -- your Airtable base id
  table_name = 'Tickets',         -- exact table name (or its "tbl..." id) in that base

  buffer = {
    fields = {                     -- rendered in this exact order when a record is opened
      { key = 'title', field = 'Title' },             -- key="title" is special: the H1 heading
      { key = 'description', field = 'Description' },
    },
  },
```

### Recommended config

If you're in a dev company team, there might hundreds of records you don't need to see to focus on your work.

- Define the fields you need in the `buffer`, to read the content you want.
- Define only the `buffer.editable` fields you need to edit.
- Define at least one default `picker` with filters to get only the ones you need to track.

```lua
require('airtable').setup({
  token_env = 'AIRTABLE_TOKEN',   -- name of the env var holding your token (not the token itself)
  base_id = 'appXXXXXXXXXXXXXX',  -- your Airtable base id
  table_name = 'Tickets',         -- exact table name (or its "tbl..." id) in that base
  page_size = 20,                -- records fetched per API page (Airtable max: 100)
  default_filter = 'Assigned to me', -- picker opened by `:Airtable` with no argument

  buffer = {
    fields = {                     -- rendered in this exact order when a record is opened
      { key = 'title', field = 'Title' },             -- key="title" is special: the H1 heading
      { key = 'status', field = 'Status' },            -- other keys become their own "## <Key>" section
      { key = 'description', field = 'Description' },
    },
    -- Optional and off by default. Each entry adds an "Edit <field>" action to the
    -- record view's <CR> menu. This is a WRITE operation — see "Editing fields" below.
    editable = {
      { field = 'Status', type = 'select' },              -- opens a picker of the field's choices
      { field = 'PR link', type = 'text', name = 'Edit PR link' }, -- opens a small editable buffer
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
})
```

> Every field name above must match your Airtable base's actual column names exactly
> (case-sensitive).

### Record styling

Colors adapt to your colorscheme and never break the render.

<details>
<summary><b>Advanced settings</b> (optional, click to expand)</summary>

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

#### `result_line[].hl`: conditional per-value colors

Instead of one fixed color per section, `hl` can be a list of `{ value, color }` rules:

```lua
result_line = {
  {
    field = 'Status',
    hl = {
      { value = 'To do', color = '#E32424' },
      { value = 'In progress', color = '#FFBF5E' },
      { value = 'Done', color = '#5F94E3' },
    },
  },
  { field = 'Title' },
},
```

#### `date_format`:

Add `date_format` explicitly to a `buffer.fields` or `result_line` entry to override the
auto-detected default, e.g. to show only the time, or `date` in the buffer too:

| Value                               | Result             |
| ----------------------------------- | ------------------ |
| `date_format = 'datetime` (default) | 01/01/2026 - 21:09 |
| `date_format = 'date` (default)     | 01/01/2026         |
| `date_format = 'time` (default)     | 21:09              |

```lua
buffer = {
  fields = {
    { key = 'title', field = 'Title' },
    { key = 'created_at', field = 'Created At', date_format = 'datetime' }, -- explicit, same as auto-detected default
  },
},
pickers = {
  {
    name = 'Tickets',
    result_line = {
      { field = 'Title' },
      { field = 'Created At', date_format = 'time' }, -- override: show only "21:09"
    },
  },
},
```

##### `date_formats`: customizing the templates

Override the display template for each mode globally, wherever `date_format` applies
(explicit or auto-detected). Placeholders: `{DD}`, `{MM}`, `{YYYY}`, `{HH}`, `{mm}`.

```lua
require('airtable').setup({
  -- ...
  date_formats = {
    datetime = '{YYYY}-{MM}-{DD} {HH}h{mm}', -- default: '{DD}/{MM}/{YYYY} - {HH}:{mm}'
    date = '{YYYY}-{MM}-{DD}',               -- default: '{DD}/{MM}/{YYYY}'
    time = '{HH}h{mm}',                      -- default: '{HH}:{mm}'
  },
})
```

</details>

## Usage

```vim
:Airtable                  " open the default picker
:Airtable Open bugs        " open a specific picker by name
```

### Search

Typing in the picker fuzzy-matches the visible result line by default (title, status,
whatever `result_line` shows). Prefix your query with `--` to instead search the full
content of every `buffer.fields` value.

```
feature-flag-xyz         " matches only if it's in the visible row
--feature-flag-xyz       " matches anywhere in the record's configured fields
```

Inside a record buffer, press `<CR>` for quick actions: open in browser, browse comments,
copy the record's URL, or edit a field (if `buffer.editable` is configured). With the
cursor on a URL anywhere in the buffer, `o` opens it in your browser and `c` copies it.

### Editing fields

> **This writes to Airtable.** Only fields you explicitly list in `buffer.editable` can
> ever be edited, nothing else in this plugin modifies your data.

Each `buffer.editable` entry adds an "Edit `<field>`" (or a custom `name`) action to the
`<CR>` menu:

- **`type = 'select'`** — opens a Telescope picker listing the field's valid choices
  (fetched from Airtable). Pressing `<CR>` on a choice saves it immediately.
- **`type = 'text'`** — opens a large centered floating buffer prefilled with the
  field's current value. Edit it like a normal buffer, then `<C-CR>` to save, or `:q` to
  discard your changes.

After a successful edit, the record buffer refreshes in place to show the new value.

### Keymaps

```lua
vim.keymap.set('n', '<leader>aa', function() require('airtable').open() end, { desc = 'Airtable' })
vim.keymap.set('n', '<leader>ab', function() require('airtable').open('Open bugs') end, { desc = 'Airtable: open bugs' })
```

## Scope

- Read-only by default. The only write operation is editing a field you've explicitly
  listed in `buffer.editable`, every other action (browsing, previewing, comments)
  never modifies your data.
- No local caching — every command re-fetches from the API.
