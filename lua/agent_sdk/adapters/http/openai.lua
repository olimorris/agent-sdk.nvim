--=============================================================================
-- OpenAI - Ported from CodeCompanion's codecompanion/adapters/http/openai_legacy.lua
--=============================================================================
local adapter_utils = require("agent_sdk.adapters.utils")
local parameters = require("agent_sdk.adapters.parameters")
local tool_formats = require("agent_sdk.adapters.tools")

local CONSTANTS = {
  STANDARD_MESSAGE_FIELDS = {
    "annotations",
    "audio",
    "content",
    "function_call",
    "refusal",
    "role",
    "tool_calls",
  },
  STANDARD_TOOL_CALL_FIELDS = {
    "id",
    "type",
    "function",
    "index",
  },
}

---Find the fields in a `message` or `delta` that aren't in OpenAI's Chat Completions spec
---@param delta table?
---@return table|nil
local function find_extra_fields(delta)
  if delta == nil then
    return nil
  end
  local extra = {}
  vim.iter(delta):each(function(k, v)
    if not vim.list_contains(CONSTANTS.STANDARD_MESSAGE_FIELDS, k) then
      extra[k] = v
    end
  end)
  if not vim.tbl_isempty(extra) then
    return extra
  end
end

---@param opts { tool: table, index: number, id: string }
---@return table
local function create_tool_data(opts)
  local tool = opts.tool
  local tool_data = {
    _index = opts.index,
    id = opts.id,
    type = tool.type,
    ["function"] = {
      name = tool["function"]["name"],
      arguments = tool["function"]["arguments"] or "",
    },
  }

  for key, value in pairs(tool) do
    if not vim.tbl_contains(CONSTANTS.STANDARD_TOOL_CALL_FIELDS, key) then
      tool_data[key] = value
    end
  end

  return tool_data
end

---@type agent_sdk.HTTPAdapter
return {
  name = "openai",
  formatted_name = "OpenAI",
  type = "http",
  roles = {
    llm = "assistant",
    user = "user",
    tool = "tool",
  },
  opts = {
    stream = true,
    tools = true,
    vision = true,
  },
  url = "https://api.openai.com/v1/chat/completions",
  env = {
    api_key = "OPENAI_API_KEY",
  },
  headers = {
    ["Content-Type"] = "application/json",
    Authorization = "Bearer ${api_key}",
  },
  temp = {
    input_tokens = 0,
  },
  model = "gpt-4.1",
  models = {
    -- Frontier models
    ["gpt-5.6-sol"] = {
      formatted_name = "GPT 5.6 Sol",
      meta = { context_window = 1050000 },
      opts = {
        can_reason = true,
        has_vision = true,
      },
    },
    ["gpt-5.6-terra"] = {
      formatted_name = "GPT 5.6 Terra",
      meta = { context_window = 1050000 },
      opts = {
        can_reason = true,
        has_vision = true,
      },
    },
    ["gpt-5.6-luna"] = {
      formatted_name = "GPT 5.6 Luna",
      meta = { context_window = 1050000 },
      opts = {
        can_reason = true,
        has_vision = true,
      },
    },

    -- Older models
    ["gpt-5.5"] = {
      formatted_name = "GPT 5.5",
      meta = { context_window = 1050000 },
      opts = {
        can_reason = true,
        has_vision = true,
      },
    },
    ["gpt-5.4"] = {
      formatted_name = "GPT 5.4",
      meta = { context_window = 1050000 },
      opts = { can_reason = true, has_vision = true },
    },
    ["gpt-5.4-mini"] = {
      formatted_name = "GPT 5.4 Mini",
      meta = { context_window = 400000 },
      opts = { can_reason = true, has_vision = true },
    },
    ["gpt-5.4-nano"] = {
      formatted_name = "GPT 5.4 Nano",
      meta = { context_window = 400000 },
      opts = { can_reason = true, has_vision = true },
    },
    ["gpt-5"] = {
      formatted_name = "GPT 5",
      meta = { context_window = 400000 },
      opts = { can_reason = true, has_vision = true },
    },
    ["gpt-5-mini"] = {
      formatted_name = "GPT 5 Mini",
      meta = { context_window = 400000 },
      opts = { can_reason = true, has_vision = true },
    },
    ["gpt-5-nano"] = {
      formatted_name = "GPT 5 Nano",
      meta = { context_window = 400000 },
      opts = { can_reason = true, has_vision = true },
    },
    ["gpt-4.1"] = {
      formatted_name = "GPT 4.1",
      meta = { context_window = 1047576 },
      opts = { has_vision = true },
    },
    ["o4-mini-2025-04-16"] = {
      formatted_name = "o4 Mini",
      opts = { can_reason = true, has_vision = true },
    },
    ["o3-mini-2025-01-31"] = {
      formatted_name = "o3 Mini",
      opts = { can_reason = true },
    },
    ["o3-2025-04-16"] = {
      formatted_name = "o3",
      opts = { can_reason = true, has_vision = true },
    },
    ["o1-2024-12-17"] = {
      formatted_name = "o1",
      opts = { can_reason = true, has_vision = true },
    },
    ["gpt-4o"] = {
      formatted_name = "GPT-4o",
      opts = { has_vision = true },
    },
    ["gpt-4o-mini"] = {
      formatted_name = "GPT-4o Mini",
      opts = { has_vision = true },
    },
    ["gpt-4-turbo-preview"] = {
      formatted_name = "GPT-4 Turbo Preview",
      opts = { has_vision = true },
    },
    ["gpt-4"] = {},
    ["gpt-3.5-turbo"] = {},
  },
  handlers = {
    lifecycle = {
      setup = function(self)
        self.opts.vision = true

        local model_opts = adapter_utils.model_choice(self)
        if type(model_opts) == "table" and model_opts.opts then
          self.opts = vim.tbl_deep_extend("force", self.opts, model_opts.opts)
          if not model_opts.opts.has_vision then
            self.opts.vision = false
          end
        end

        if self.opts and self.opts.stream then
          self.parameters.stream = true
          self.parameters.stream_options = { include_usage = true }
        end

        return true
      end,
    },

    request = {
      build_parameters = function(self, args)
        return parameters.translate("openai", args.params, adapter_utils.model_choice(self))
      end,

      build_messages = function(self, args)
        local model = adapter_utils.model(self) or ""

        local messages = vim
          .iter(args.messages)
          :map(function(m)
            if vim.startswith(model, "o1") and m.role == "system" then
              m.role = self.roles.user
            end

            local tool_calls = nil
            if m.tools and m.tools.calls then
              tool_calls = vim
                .iter(m.tools.calls)
                :map(function(tool_call)
                  return {
                    id = adapter_utils.pairing_id(tool_call),
                    ["function"] = tool_call["function"],
                    type = tool_call.type,
                  }
                end)
                :totable()
            end

            local result = {
              role = m.role,
              content = m.content,
              tool_calls = tool_calls,
              tool_call_id = m.tools and m.tools.call_id or nil,
            }

            -- Extensions like Copilot carry reasoning that must be sent back
            if m.reasoning then
              result.reasoning = m.reasoning
            end

            return result
          end)
          :totable()

        return { messages = messages }
      end,

      build_tools = function(self, args)
        if not self.opts.tools then
          return nil
        end
        return { tools = tool_formats.translate("openai", args.tools) }
      end,
    },

    response = {
      parse_tokens = function(self, args)
        local data = args.data
        if data and data ~= "" then
          local ok, json =
            pcall(vim.json.decode, adapter_utils.clean_streamed_data(data), { luanil = { object = true } })
          if ok and type(json) == "table" and json.usage then
            -- The session reports output tokens as the total minus this
            self.temp.input_tokens = json.usage.prompt_tokens or 0
            return json.usage.total_tokens
          end
        end
      end,

      parse_chat = function(self, args)
        local data, tools = args.data, args.tools
        if not data or data == "" then
          return nil
        end

        local data_mod = type(data) == "table" and data.body or adapter_utils.clean_streamed_data(data)
        local ok, json = pcall(vim.json.decode, data_mod, { luanil = { object = true } })

        if not ok or type(json) ~= "table" or not json.choices or #json.choices == 0 then
          return nil
        end

        if self.opts.tools and tools then
          for _, choice in ipairs(json.choices) do
            local delta = self.opts.stream and choice.delta or choice.message

            if delta and delta.tool_calls and #delta.tool_calls > 0 then
              for i, tool in ipairs(delta.tool_calls) do
                local tool_index = tool.index and tonumber(tool.index) or i

                -- Some endpoints, like Gemini's, leave the id out
                local id = tool.id
                if not id or id == "" then
                  id = string.format("call_%s_%s", json.created, i)
                end

                if self.opts.stream then
                  local found = false
                  for _, existing_tool in ipairs(tools) do
                    if existing_tool._index == tool_index then
                      if tool["function"] and tool["function"]["arguments"] then
                        existing_tool["function"]["arguments"] = (existing_tool["function"]["arguments"] or "")
                          .. tool["function"]["arguments"]
                      end
                      found = true
                      break
                    end
                  end

                  if not found then
                    table.insert(tools, create_tool_data({ tool = tool, index = tool_index, id = id }))
                  end
                else
                  table.insert(tools, create_tool_data({ tool = tool, index = i, id = id }))
                end
              end
            end
          end
        end

        local choice = json.choices[1]
        local delta = self.opts.stream and choice.delta or choice.message

        if not delta then
          return nil
        end

        return {
          status = "success",
          output = {
            role = delta.role,
            content = delta.content,
          },
          extra = find_extra_fields(delta),
        }
      end,
    },

    tools = {
      format_calls = function(self, args)
        -- Ref: https://platform.openai.com/docs/guides/function-calling?api-mode=chat#handling-function-calls
        return args.tools
      end,
    },
  },
}
