-- Offline runner using already installed mini.nvim. No bootstrap or installs.
vim.opt.rtp:prepend(vim.uv.cwd())
vim.opt.rtp:append(assert(vim.env.SIDEKICK_MINI_TEST, "Set SIDEKICK_MINI_TEST to installed mini.nvim or mini.test"))
local MiniTest = require("mini.test")
MiniTest.setup({
  collect = {
    find_files = function()
      return { "tests/herdr_poc.lua" }
    end,
  },
  execute = { reporter = MiniTest.gen_reporter.stdout({ quit_on_finish = true }) },
})
MiniTest.run()
