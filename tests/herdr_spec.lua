local T = require("mini.test").new_set()
T["isolated herdr mock regression suite"] = function()
  if vim.uv.os_uname().sysname ~= "Linux" then
    MiniTest.skip("Herdr PoC requires local Linux process identity")
  end
  local runtime = assert(vim.api.nvim_get_runtime_file("lua/mini/test.lua", false)[1])
  local mini = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(runtime)))
  local result = vim
    .system({ "bash", "scripts/test-herdr-poc" }, {
      text = true,
      timeout = 60000,
      env = { SIDEKICK_MINI_TEST = mini },
    })
    :wait()
  MiniTest.expect.equality(result.code, 0, (result.stdout or "") .. (result.stderr or ""))
end
return T
