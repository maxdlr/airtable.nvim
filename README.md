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
- [snacks.nvim](https://github.com/folke/snacks.nvim)
- [honcho.nvim](https://github.com/maxdlr/honcho.nvim)

## Installation

<details open>
<summary><code>vim.pack</code> (built-in, Neovim ≥ 0.12)</summary>

```lua
vim.pack.add({
  'https://github.com/nvim-lua/plenary.nvim',
  'https://github.com/folke/snacks.nvim',
  'https://github.com/maxdlr/honcho.nvim',
  'https://github.com/maxdlr/airtable.nvim',
})
```

</details>

<details>
<summary><a href="https://github.com/folke/lazy.nvim">lazy.nvim</a></summary>

```lua
{
  'you/airtable.nvim',
  dependencies = { 'nvim-lua/plenary.nvim', 'folke/snacks.nvim', 'maxdlr/honcho.nvim' },
  opts = { --[[ see Configuration below ]] },
}
```

</details>

<details>
<summary><a href="https://github.com/wbthomason/packer.nvim">packer.nvim</a></summary>

```lua
use({
  'you/airtable.nvim',
  requires = { 'nvim-lua/plenary.nvim', 'folke/snacks.nvim', 'maxdlr/honcho.nvim' },
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

<details>
<summary><b>Default config</b> (click to expand)</summary>

```lua
require('airtable').setup({
  token_env = 'AIRTABLE_TOKEN',
  base_id = '',
  table_name = '',
  page_size = 20,
  default_filter = 'All records',

  buffer = {
    fields = {
      { key = 'title', field = 'Title' },
      { key = 'status', field = 'Status' },
      { key = 'description', field = 'Description' },
    },
  },

  pickers = {
    {
      name = 'All records',
      result_line = {
        { field = 'Status' },
        { field = 'Title' },
        { field = 'Description' },
      },
    },
  },
})
```

</details>

### Minimum config

```lua
require('airtable').setup({
  token_env = 'AIRTABLE_TOKEN', -- name of the env var holding your token (not the token itself)
  base_id = 'appXXXXXXXXXXXXXX',
  table_name = 'Tickets',
})
```

If you skip `pickers` entirely, `:Airtable` lists every record in `table_name` — no
filters required to get started.

> Every field name above must match your Airtable base's actual column names exactly
> (case-sensitive) — there's no universal default, since this varies by base.

### Recommended config

```lua
require('airtable').setup({
  token_env = 'AIRTABLE_TOKEN',
  base_id = 'appXXXXXXXXXXXXXX',                      -- your Airtable base id
  table_name = 'Tickets',                             -- exact table name (or its "tbl..." id) in that base
  page_size = 20,                                     -- records fetched per API page (Airtable max: 100)
  default_filter = 'Assigned to me',                  -- picker opened by `:Airtable` with no argument

  buffer = {
    fields = {                                        -- rendered in this exact order when a record is opened
      { key = 'title', field = 'Title' },             -- key="title" is special: the H1 heading
      { key = 'status', field = 'Status' },           -- other keys become their own "## <Key>" section
      { key = 'description', field = 'Description' },
    },

    -- Optional, off by default. This is a WRITE operation — see "Editing fields" below.
    editable = {
      { field = 'Status', type = 'select' },                       -- pick from the field's choices
      { field = 'PR link', type = 'text', name = 'Edit PR link' }, -- edit it directly in the buffer
    },

    autosave = { enabled = true, debounce_ms = 1000 },  -- text edits save 1s after you stop typing
  },

  pickers = {                                           -- one or more named views, switch between them by name
    {
      name = 'Assigned to me',                          -- shown in the picker title; used to select this view
      filters = {                                       -- conditions combined with AND (omit to list everything)
        { field = 'Assignee', value = 'Your Name' },    -- matches even array-shaped fields
        { field = 'Type', value = 'Bug', only = true }, -- only=true: exact match instead
        { field = 'Assignee', value = 'you@co.com', by = 'email' }, -- exact collaborator email match
      },
      sort = { field = 'Priority', order = 'asc' },     -- optional; order: 'asc' or 'desc'
      result_line = {                                   -- columns shown per row, left to right
        { field = 'Title' },                            -- hl omitted: defaults to an identifier color
        { field = 'Status', hl = '#FFA500' },           -- hl: a highlight group or hex color
      },
    },
  },
})
```

### Record styling

Opening a record (and its picker preview) styles each `buffer.fields` entry based on
its key name, no configuration needed:

- Keys like `status`, `assignee`, `reviewer`, `type`, `priority`, or `label` render as a
  colored pill — the color is derived deterministically from the field's value, so the
  same value always gets the same color.
- Keys like `name`, `title`, or `id` render with heading-style emphasis.
- Everything else renders as plain text with a left border bar.

Colors adapt to your colorscheme and never break the render — if a color can't be
resolved for any reason, the plugin falls back to plain, unstyled text.

<details>
<summary><b>Advanced settings</b> (optional, click to expand)</summary>

#### `buffer.style.section_border_character`: left border glyph

Plain-style sections (heading + body) get a left border bar down the whole section.
Defaults to `"▌"`; override it with any single character. Sections listed in
`buffer.editable` get a distinct border color (default: orange, `"#FFA500"`), override
with `editable_section_border_color`:

```lua
buffer = {
  fields = { --[[ ... ]] },
  editable = { --[[ ... ]] },
  style = {
    section_border_character = '|',
    editable_section_border_color = '#D1FF1B',
  },
},
```

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
      -- condition uses the same shape as `filters`
      { '📝', { field = 'Status', value = 'In progress' } },
      { '▶️', { field = 'Status', value = 'To do' } },
      { '✅', { field = 'Status', value = 'Done', only = true } },
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

#### `date_format`

Add `date_format` explicitly to a `buffer.fields` or `result_line` entry to override the
auto-detected default:

| Value                                | Result                                                 |
| ------------------------------------ | ------------------------------------------------------ |
| `date_format = 'datetime'` (default) | 01/01/2026 - 21:09                                     |
| `date_format = 'date'` (default)     | 01/01/2026                                             |
| `date_format = 'time'` (default)     | 21:09                                                  |
| `date_format = 'short_date'`         | 27/10, or 10/12/2025 if the year isn't the current one |

```lua
buffer = {
  fields = {
    { key = 'title', field = 'Title' },
    { key = 'created_at', field = 'Created At', date_format = 'datetime' },
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

Override the display template for each mode globally. Placeholders: `{DD}`, `{MM}`,
`{YYYY}`, `{HH}`, `{mm}`.

```lua
require('airtable').setup({
  -- ...
  date_formats = {
    datetime = '{YYYY}-{MM}-{DD} {HH}h{mm}', -- default: '{DD}/{MM}/{YYYY} - {HH}:{mm}'
    date = '{YYYY}-{MM}-{DD}',               -- default: '{DD}/{MM}/{YYYY}'
    time = '{HH}h{mm}',                      -- default: '{HH}:{mm}'
    short_date = '{DD}.{MM}',                -- default: '{DD}/{MM}'
  },
})
```

</details>

## Usage

```vim
:Airtable                  " open the default picker
:Airtable Open bugs        " open a specific picker by name
:AirtableResume             " reopen the last viewed record, or the default picker if none
```

### Search

Typing in the picker fuzzy-matches the visible result line by default (title, status,
whatever `result_line` shows). Prefix your query with `--` to instead search the full
content of every `buffer.fields` value — description, notes, anything not shown in the
row — useful for finding a record by pasting a snippet, a feature flag name, or any text
that only appears in a long field. Entirely local (no extra API calls): it searches the
records already fetched for the current picker.

```
feature-flag-xyz         " matches only if it's in the visible row
--feature-flag-xyz       " matches anywhere in the record's configured fields
```

Pressing `<CR>` on a record opens an action menu: open in buffer, open in browser, copy
URL, and an "Edit `<field>`" action for every `buffer.editable` entry. Select fields open
their choices on top of the picker; text fields open the record buffer with the cursor at
the end of that field, in insert mode. Every action keeps the picker open except opening
in a buffer and editing a text field.

Inside a record buffer:

| Key    | Action                                                                        |
| ------ | ----------------------------------------------------------------------------- |
| `<CR>` | Actions: open in browser, browse comments, copy URL, refresh, edit a field    |
| `go`   | Open the URL under the cursor                                                 |
| `e`    | On a `select` field's section: pick a new value. Elsewhere: the usual motion. |
| `:w`   | Save pending text edits now                                                   |

### Editing fields

> **This writes to Airtable.** Only fields you explicitly list in `buffer.editable` can
> ever be edited.

- **`type = 'text'`** — edit the field directly in the record buffer, with any Vim
  motion or operator. Changes are saved automatically `buffer.autosave.debounce_ms`
  (default 1000) after you stop typing, all changed fields in one request. They're also
  saved right away on `:w`, when you leave the buffer, and when Neovim exits.
  - Everything that isn't an editable field is read-only. Typing there is refused, and
    an edit that crosses into it (e.g. `dG`) is reverted, keeping your field changes.
  - Single-line fields (single line text, URL, email, phone, number) can't get a line
    break. Number fields are sent as numbers, and an empty number field clears it.
  - Supported for text and number fields. Other field types listed as `text` stay
    read-only, with a warning.
  - The end of the title line shows the save state: `● unsaved`, `… saving`,
    `✓ saved`, or `✗ not saved` (it retries with your next edit, and `:w`). While
    edits are unsaved the buffer is `'modified'`, so `:q` warns you.
  - Set `buffer.autosave.enabled = false` to only save on `:w`.
- **`type = 'select'`** — opens a picker listing the field's valid choices. Pressing
  `<CR>` on a choice saves it immediately, then the record buffer refreshes in place
  (unsaved text edits are saved first and kept).

### Keymaps

```lua
vim.keymap.set('n', '<leader>aa', function() require('airtable').open() end, { desc = 'Airtable' })
vim.keymap.set('n', '<leader>ab', function() require('airtable').open('Open bugs') end, { desc = 'Airtable: open bugs' })
vim.keymap.set('n', '<leader>ar', function() require('airtable').resume() end, { desc = 'Airtable: resume' })
```

## Scope

- Read-only by default. The only write operation is editing a field you've explicitly
  listed in `buffer.editable`.
- No local caching of records — every command re-fetches them from the API. The table
  schema (field types, select choices, table id) is cached for the session.

## Development

```sh
make test   # headless Neovim + plenary.nvim (set PLENARY_DIR to point at your copy)
```
