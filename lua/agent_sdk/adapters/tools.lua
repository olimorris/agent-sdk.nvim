--=============================================================================
-- Tools - turn the SDK's tool definitions into each API's own
--=============================================================================

---@class agent_sdk.Tool
---@field description string What the tool does, written for the model
---@field name string
---@field parameters? table A JSON Schema object for the tool's arguments

local M = {}

-- The names every API accepts: Gemini wants a leading letter or underscore, and Anthropic and OpenAI stop at 64
local NAME_PATTERN = "^[%a_][%w_%-]*$"
local NAME_MAX = 64

-- Keys whose value is a JSON object, so an empty Lua table must be sent as {} and not []
local OBJECT_KEYS = { ["$defs"] = true, definitions = true, patternProperties = true, properties = true }

---@param schema table
---@return table
local function to_json_schema(schema)
  local copy = {}
  for key, value in pairs(schema) do
    if type(value) == "table" then
      value = (OBJECT_KEYS[key] and next(value) == nil) and vim.empty_dict() or to_json_schema(value)
    end
    copy[key] = value
  end
  return copy
end

---@param tool agent_sdk.Tool
---@return table
local function parameters(tool)
  return to_json_schema(tool.parameters or { type = "object", properties = {} })
end

---@type table<string, fun(tools: agent_sdk.Tool[]): table>
M.formats = {
  -- Ref: https://platform.claude.com/docs/en/agents-and-tools/tool-use/define-tools
  anthropic = function(tools)
    return vim.tbl_map(function(tool)
      return { name = tool.name, description = tool.description, input_schema = parameters(tool) }
    end, tools)
  end,

  -- Ref: https://ai.google.dev/api/caching#FunctionDeclaration
  gemini = function(tools)
    local declarations = vim.tbl_map(function(tool)
      return { name = tool.name, description = tool.description, parametersJsonSchema = parameters(tool) }
    end, tools)
    return { { functionDeclarations = declarations } }
  end,

  -- Ref: https://platform.openai.com/docs/api-reference/chat/create#chat-create-tools
  openai = function(tools)
    return vim.tbl_map(function(tool)
      return {
        type = "function",
        ["function"] = { name = tool.name, description = tool.description, parameters = parameters(tool) },
      }
    end, tools)
  end,

  -- Ref: https://platform.openai.com/docs/api-reference/responses/create#responses-create-tools
  openai_responses = function(tools)
    return vim.tbl_map(function(tool)
      return { type = "function", name = tool.name, description = tool.description, parameters = parameters(tool) }
    end, tools)
  end,
}

---Check a plugin's tool definitions, so a mistake fails in the plugin and not as a provider's 400
---@param tools any
---@return boolean ok, string|nil err
function M.validate(tools)
  if type(tools) ~= "table" or not vim.islist(tools) then
    return false, "tools must be a list"
  end
  local seen = {}
  for index, tool in ipairs(tools) do
    local name = type(tool) == "table" and tool.name
    if type(name) ~= "string" or not name:match(NAME_PATTERN) or #name > NAME_MAX then
      return false,
        ("tool %d needs a name of letters, digits, _ or -, starting with a letter or _, and at most %d long"):format(
          index,
          NAME_MAX
        )
    end
    if seen[name] then
      return false, ('two tools are named "%s"'):format(name)
    end
    seen[name] = true
    if type(tool.description) ~= "string" or tool.description == "" then
      return false, ('tool "%s" needs a description'):format(name)
    end
    if tool.parameters ~= nil and (type(tool.parameters) ~= "table" or tool.parameters.type ~= "object") then
      return false, ('tool "%s" needs parameters that are a JSON Schema with type = "object"'):format(name)
    end
  end
  return true
end

---Turn the SDK's tools into the value of the target API's `tools` field
---@param format "anthropic"|"gemini"|"openai"|"openai_responses"
---@param tools agent_sdk.Tool[]
---@return table
function M.translate(format, tools)
  local translate = M.formats[format]
  if not translate then
    error(("agent-sdk.nvim: no tool format named %s"):format(vim.inspect(format)), 2)
  end
  return translate(tools)
end

return M
