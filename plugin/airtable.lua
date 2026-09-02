if vim.g.loaded_airtable then return end
vim.g.loaded_airtable = true

vim.api.nvim_create_user_command('Airtable', function(opts)
  require('airtable').open(opts.args ~= '' and opts.args or nil)
end, {
  nargs = '?',
  desc = 'Open Airtable records picker (optionally with a filter name)',
  complete = function()
    return require('airtable').filter_names()
  end,
})
