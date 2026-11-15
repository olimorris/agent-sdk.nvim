local adapters = require("agent_sdk.adapters")

local M = {}

local function validate(replies)
  for index, reply in ipairs(replies) do
    local last = reply[#reply]
    if not last or (last.type ~= "done" and last.type ~= "error") then
      error(("agent_sdk.test: reply %d must end with a done or error event"):format(index), 3)
    end
  end
end

---@class agent_sdk.TestOpts
---@field type "http"|"acp"?
---@field capabilities table?
---@field model string?
---@field replies table[][]?

---@param opts agent_sdk.TestOpts?
---@return table
function M.adapter(opts)
  opts = opts or {}
  local replies = opts.replies or {}
  validate(replies)

  local scripted = {
    type = opts.type or "http",
    capabilities = vim.tbl_deep_extend("force", adapters.default_capabilities(), opts.capabilities or {}),
    model = opts.model,
    responses = {},
    requests = {},
  }

  local responses, requests = scripted.responses, scripted.requests
  local cursor = 0

  scripted.connect = function()
    local playbacks = {}
    local connection = {}

    function connection:request(request, emit)
      requests[#requests + 1] = request
      cursor = cursor + 1
      local number = cursor
      local script = replies[number]
      local playback = { stopped = false }
      playbacks[#playbacks + 1] = playback

      local function play(index)
        vim.schedule(function()
          if playback.stopped then
            return
          end
          if not script then
            playback.stopped = true
            return emit({ type = "error", message = "agent_sdk.test: no scripted reply for request " .. number })
          end

          local event = vim.deepcopy(script[index])
          if event.type == "permission_request" then
            event.respond = function(option_id)
              responses[#responses + 1] = option_id == nil and vim.NIL or option_id
              play(index + 1)
            end
            return emit(event)
          end

          emit(event)
          if event.type ~= "done" and event.type ~= "error" then
            play(index + 1)
          end
        end)
      end

      play(1)
      return function()
        playback.stopped = true
      end
    end

    function connection:close()
      for _, playback in ipairs(playbacks) do
        playback.stopped = true
      end
    end

    return connection
  end

  return scripted
end

return M
