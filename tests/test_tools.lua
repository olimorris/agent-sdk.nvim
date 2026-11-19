local tools = require("agent_sdk.adapters.tools")

local eq = MiniTest.expect.equality

local read_file = {
  name = "read_file",
  description = "Read a file from the user's project",
  parameters = {
    type = "object",
    properties = { path = { type = "string", description = "Relative to the project root" } },
    required = { "path" },
  },
}

local list_buffers = { name = "list_buffers", description = "List the open buffers" }

local read_file_schema = {
  type = "object",
  properties = { path = { type = "string", description = "Relative to the project root" } },
  required = { "path" },
}

local T = MiniTest.new_set()

T["anthropic takes the schema as input_schema"] = function()
  eq(tools.translate("anthropic", { read_file }), {
    { name = "read_file", description = "Read a file from the user's project", input_schema = read_file_schema },
  })
end

T["openai chat completions nests each tool under function"] = function()
  eq(tools.translate("openai", { read_file }), {
    {
      type = "function",
      ["function"] = {
        name = "read_file",
        description = "Read a file from the user's project",
        parameters = read_file_schema,
      },
    },
  })
end

T["openai responses keeps each tool flat"] = function()
  eq(tools.translate("openai_responses", { read_file }), {
    {
      type = "function",
      name = "read_file",
      description = "Read a file from the user's project",
      parameters = read_file_schema,
    },
  })
end

T["gemini groups every tool into one set of function declarations"] = function()
  eq(tools.translate("gemini", { read_file, list_buffers }), {
    {
      functionDeclarations = {
        {
          name = "read_file",
          description = "Read a file from the user's project",
          parametersJsonSchema = read_file_schema,
        },
        {
          name = "list_buffers",
          description = "List the open buffers",
          parametersJsonSchema = { type = "object", properties = vim.empty_dict() },
        },
      },
    },
  })
end

T["a tool without parameters is sent an empty object schema"] = function()
  local translated = tools.translate("anthropic", { list_buffers })
  eq(vim.json.encode(translated[1].input_schema), '{"type":"object","properties":{}}')
end

T["empty properties are encoded as a JSON object at any depth"] = function()
  local tool = {
    name = "configure",
    description = "Set options",
    parameters = {
      type = "object",
      properties = { options = { type = "object", properties = {} } },
    },
  }
  local schema = tools.translate("openai", { tool })[1]["function"].parameters
  eq(
    vim.json.decode(vim.json.encode(schema), { luanil = { object = true } }).properties.options.properties,
    vim.empty_dict()
  )
  eq(vim.json.encode(schema.properties.options), '{"type":"object","properties":{}}')
end

T["translating leaves the plugin's tables unchanged"] = function()
  local tool = vim.deepcopy(list_buffers)
  tool.parameters = { type = "object", properties = {} }
  tools.translate("anthropic", { tool })
  eq(
    tool,
    { name = "list_buffers", description = "List the open buffers", parameters = { type = "object", properties = {} } }
  )
end

T["an unknown format raises"] = function()
  MiniTest.expect.error(function()
    tools.translate("cohere", { read_file })
  end, "no tool format")
end

T["validate"] = MiniTest.new_set()

T["validate"]["accepts tools every format can send"] = function()
  eq(tools.validate({ read_file, list_buffers, { name = "_x-1", description = "d" } }), true)
end

T["validate"]["rejects what a provider would"] = function()
  local function err(list)
    return select(2, tools.validate(list))
  end
  eq(err("read_file"), "tools must be a list")
  eq(err({ { name = "read.file", description = "d" } }):match("^tool 1 needs a name") ~= nil, true)
  eq(err({ { name = "1read", description = "d" } }):match("^tool 1 needs a name") ~= nil, true)
  eq(err({ { name = string.rep("a", 65), description = "d" } }):match("^tool 1 needs a name") ~= nil, true)
  eq(err({ read_file, read_file }), 'two tools are named "read_file"')
  eq(err({ { name = "x" } }), 'tool "x" needs a description')
  eq(
    err({ { name = "x", description = "d", parameters = { type = "string" } } }),
    'tool "x" needs parameters that are a JSON Schema with type = "object"'
  )
end

return T
