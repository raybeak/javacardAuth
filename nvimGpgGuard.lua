-- Guard against plaintext leaks in swap/undo/backup/shada when handling *.gpg buffers
vim.api.nvim_create_autocmd({ "BufReadPre", "FileReadPre", "BufNewFile" }, {
  pattern = { "*.gpg", "*.asc" },
  callback = function()
    vim.opt_local.swapfile = false
    vim.opt_local.undofile = false
    vim.opt_local.backup = false
    vim.opt_local.writebackup = false
    vim.opt.shada = ""
  end,
})
