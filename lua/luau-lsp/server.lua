local Path = require "plenary.path"
local async = require "plenary.async"
local c = require "luau-lsp.config"
local compat = require "luau-lsp.compat"
local curl = require "plenary.curl"
local log = require "luau-lsp.log"
local util = require "luau-lsp.util"

local CURRENT_FFLAGS =
  "https://clientsettingscdn.roblox.com/v1/settings/application?applicationName=PCDesktopClient"

local get_fflags = async.wrap(function(callback)
  curl.get {
    url = CURRENT_FFLAGS,
    accept = "application/json",
    callback = function(result)
      callback(vim.json.decode(result.body).applicationSettings)
    end,
    compressed = false,
  }
end, 1)

local function get_args()
  local args = {}

  local function add_definition_file(file)
    if Path:new(file):is_file() then
      table.insert(args, "--definitions=" .. file)
    else
      log.warn(
        "Definitions file at `%s` does not exist, types will not be provided from this file",
        file
      )
    end
  end

  local function add_documentation_file(file)
    if Path:new(file):is_file() then
      table.insert(args, "--docs=" .. file)
    else
      log.warn("Documentations file at `%s` does not exist", file)
    end
  end

  for _, file in ipairs(c.get().types.definition_files) do
    add_definition_file(file)
  end

  for _, file in ipairs(c.get().types.documentation_files) do
    add_documentation_file(file)
  end

  if not c.get().fflags.enable_by_default then
    table.insert(args, "--no-flags-enabled")
  end

  local fflags = {}

  if c.get().fflags.sync then
    compat
      .iter(get_fflags())
      :filter(function(name)
        return name:match "^FFlagLuau"
      end)
      :map(function(name, value)
        return name:sub(6), value
      end)
      :each(function(name, value)
        fflags[name] = value
      end)
  end

  fflags = vim.tbl_extend("force", fflags, c.get().fflags.override)

  for name, value in pairs(fflags) do
    table.insert(args, string.format("--flag:%s=%s", name, value))
  end

  if c.get().types.roblox then
    local roblox = require "luau-lsp.roblox"
    local definition_file, documentation_file = roblox.download_api()

    add_definition_file(definition_file)
    add_documentation_file(documentation_file)
  end

  -- HACK: not required once luau-lsp v1.27.0+ is released
  if not c.get().sourcemap.enabled then
    -- hide luau lsp messages when sourcemap is disabled
    local no_sourcemap = Path:new(util.storage_file "no-sourcemap-enabled.json")
    if not no_sourcemap:is_file() then
      no_sourcemap:write(vim.json.encode { ["luau-lsp.sourcemap.enabled"] = false }, "w")
    end
    table.insert(args, "--settings")
    table.insert(args, tostring(no_sourcemap))
  end

  return args
end

-- patch shared settings between the client extension and server
local function patch_server_settings(settings)
  return vim.tbl_deep_extend("force", settings, {
    ["luau-lsp"] = {
      sourcemap = {
        enabled = c.get().sourcemap.enabled,
      },
    },
  })
end

-- HACK: neovim is not handling ServerCancelled, see https://github.com/neovim/neovim/issues/26926
local function patch_notify()
  local notify = vim.notify
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.notify = function(message, ...)
    if message == "luau_lsp: -32802: server not yet received configuration for diagnostics" then
      return
    end
    notify(message, ...)
  end
end

local function setup_server()
  local opts = vim.deepcopy(c.get().server)
  local bufnr = vim.api.nvim_get_current_buf()

  opts.cmd = vim.list_extend(opts.cmd, get_args())
  opts.settings = patch_server_settings(opts.settings)

  async.util.scheduler()
  require("lspconfig").luau_lsp.setup(opts)
  require("lspconfig").luau_lsp.manager:try_add_wrapper(bufnr)
end

local M = {}

function M.setup()
  patch_notify()

  vim.api.nvim_create_autocmd("FileType", {
    once = true,
    pattern = c.get().server.filetypes or { "luau" },
    callback = function()
      async.run(setup_server)
    end,
  })
end

return M
