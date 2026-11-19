--=============================================================================
-- Anthropic - Ported from CodeCompanion's codecompanion/adapters/http/anthropic.lua
--=============================================================================
local adapter_utils = require("agent_sdk.adapters.utils")
local parameters = require("agent_sdk.adapters.parameters")
local tool_formats = require("agent_sdk.adapters.tools")

---@type agent_sdk.HTTPAdapter
return {
  name = "anthropic",
  formatted_name = "Anthropic",
  type = "http",
  roles = {
    llm = "assistant",
    user = "user",
  },
  opts = {
    stream = true,
    tools = true,
    vision = true,
  },
  url = "https://api.anthropic.com/v1/messages",
  env = {
    api_key = "ANTHROPIC_API_KEY",
  },
  headers = {
    ["content-type"] = "application/json",
    ["x-api-key"] = "${api_key}",
    ["anthropic-version"] = "2023-06-01",
  },
  temp = {
    input_tokens = 0,
    output_tokens = 0,
  },
  model = "claude-sonnet-5",
  models = {
    ["claude-fable-5-2"] = {
      formatted_name = "Fable 5.2",
      meta = { max_tokens = 64000 },
      opts = { can_reason = true, has_vision = true },
    },
    ["claude-opus-5-5"] = {
      formatted_name = "Opus 5.5",
      meta = { max_tokens = 64000 },
      opts = { can_reason = true, has_vision = true },
    },
    ["claude-sonnet-5-5"] = {
      formatted_name = "Sonnet 5.5",
      meta = { max_tokens = 64000 },
      opts = { can_reason = true, has_vision = true },
    },
    ["claude-sonnet-5"] = {
      formatted_name = "Sonnet 5",
      meta = { max_tokens = 64000 },
      opts = { can_reason = true, has_vision = true },
    },
    ["claude-haiku-5-5"] = {
      formatted_name = "Haiku 5.5",
      meta = { max_tokens = 64000 },
      opts = { can_reason = true, has_vision = true },
    },
  },
  handlers = {
    lifecycle = {
      setup = function(self)
        if self.opts and self.opts.stream then
          self.parameters.stream = true
        end

        local model_opts = adapter_utils.model_choice(self)
        if model_opts and model_opts.opts then
          self.opts = vim.tbl_deep_extend("force", self.opts, model_opts.opts)
          if not model_opts.opts.has_vision then
            self.opts.vision = false
          end
        end

        return true
      end,
    },

    request = {
      build_parameters = function(self, args)
        local model = adapter_utils.model_choice(self)
        local params = parameters.translate("anthropic", args.params, model)

        params.max_tokens = params.max_tokens or vim.tbl_get(model or {}, "meta", "max_tokens") or 4096

        if model and model.opts and model.opts.can_reason then
          -- Ref: https://platform.claude.com/docs/en/build-with-claude/extended-thinking
          if params.thinking == nil then
            params.thinking = { type = "adaptive" }
          end
        else
          params.thinking = nil
        end

        if params.thinking and params.thinking.type ~= "disabled" then
          -- Thinking isn't compatible with top_k
          -- Ref: https://platform.claude.com/docs/en/build-with-claude/extended-thinking#feature-compatibility
          params.top_k = nil

          -- top_p must be between 1 and 0.95
          if params.top_p and (params.top_p > 1 or params.top_p < 0.95) then
            params.top_p = 1
          end
        end

        return params
      end,

      build_messages = function(self, args)
        local messages = args.messages
        local has_tools = false

        -- 1. Extract and format system messages
        local system = vim
          .iter(messages)
          :filter(function(msg)
            return msg.role == "system" and msg.content and msg.content ~= ""
          end)
          :map(function(msg)
            return { type = "text", text = msg.content }
          end)
          :totable()
        system = next(system) and system or nil

        -- 2. Remove any system messages from the regular messages
        messages = vim
          .iter(messages)
          :filter(function(msg)
            return msg.role ~= "system"
          end)
          :totable()

        messages = vim.tbl_map(function(m)
          -- 3. Remove disallowed keys
          m = adapter_utils.filter_out_messages({
            message = m,
            allowed_words = { "content", "role", "reasoning", "tools" },
          })

          -- 4. Turn string content into { { type = "text", text } }
          if m.role == self.roles.user or m.role == self.roles.llm then
            -- Anthropic doesn't allow the user to submit an empty prompt
            if m.role == self.roles.user and m.content == "" then
              m.content = "<prompt></prompt>"
            end

            if type(m.content) == "string" then
              m.content = m.content ~= "" and { { type = "text", text = m.content } } or {}
            end
          end

          if m.tools and m.tools.calls and vim.tbl_count(m.tools.calls) > 0 then
            has_tools = true
          end

          -- 5. Treat 'tool' role as user and convert tool results to Anthropic format
          if m.role == "tool" then
            m.role = self.roles.user
            if m.tools then
              m.content = {
                {
                  type = "tool_result",
                  tool_use_id = m.tools.call_id,
                  content = m.content,
                  is_error = m.tools.is_error or false,
                },
              }
              m.tools = nil
            end
          end

          -- 6. Convert any LLM tool_calls into content blocks
          if has_tools and m.role == self.roles.llm and m.tools and m.tools.calls then
            m.content = m.content or {}
            for _, call in ipairs(m.tools.calls) do
              local call_args = call["function"].arguments
              table.insert(m.content, {
                type = "tool_use",
                id = call.id,
                name = call["function"].name,
                input = call_args ~= "" and vim.json.decode(call_args) or vim.empty_dict(),
              })
            end
            m.tools = nil
          end

          -- 7. If reasoning is present, format it as a content block
          -- Reasoning carried over from another endpoint has no signature, and is dropped
          if m.reasoning and m.reasoning._data and m.reasoning._data.signature and type(m.content) == "table" then
            -- Ref: https://docs.anthropic.com/en/docs/build-with-claude/extended-thinking#how-extended-thinking-works
            table.insert(m.content, 1, {
              type = "thinking",
              thinking = m.reasoning.content,
              signature = m.reasoning._data.signature,
            })
          end
          m.reasoning = nil

          return m
        end, messages)

        -- 8. Merge consecutive messages with the same role
        messages = adapter_utils.merge_messages(messages)

        -- 9. Ensure that any consecutive tool results are merged
        if has_tools then
          for _, m in ipairs(messages) do
            if m.role == self.roles.user and type(m.content) == "table" then
              if m.content.type then
                m.content = { m.content }
              end
              local consolidated = {}
              for _, block in ipairs(m.content) do
                local prev = consolidated[#consolidated]
                if
                  block.type == "tool_result"
                  and prev
                  and prev.type == "tool_result"
                  and prev.tool_use_id == block.tool_use_id
                then
                  prev.content = prev.content .. block.content
                else
                  table.insert(consolidated, block)
                end
              end
              m.content = consolidated
            end
          end
        end

        return {
          system = system,
          messages = messages,

          -- Ref: https://platform.claude.com/docs/en/build-with-claude/prompt-caching#automatic-caching
          cache_control = { type = "ephemeral" },
        }
      end,

      build_tools = function(self, args)
        if not self.opts.tools then
          return nil
        end
        return { tools = tool_formats.translate("anthropic", args.tools) }
      end,

      build_reasoning = function(self, args)
        local data = args.data
        local content = vim
          .iter(data)
          :map(function(item)
            return item.content
          end)
          :filter(function(item)
            return item ~= nil
          end)
          :join("")

        local signature
        for _, item in ipairs(data) do
          signature = item.signature or signature
        end

        return {
          content = content,
          _data = {
            signature = signature,
          },
        }
      end,
    },

    response = {
      parse_tokens = function(self, args)
        local data = args.data
        if not data then
          return
        end
        if self.opts.stream then
          if type(data) == "string" and string.sub(data, 1, 6) == "event:" then
            return
          end
          data = adapter_utils.clean_streamed_data(data)
        else
          data = data.body
        end
        local ok, json = pcall(vim.json.decode, data)

        if ok and type(json) == "table" then
          if json.type == "message_start" then
            self.temp.input_tokens = (json.message.usage.input_tokens or 0)
              + (json.message.usage.cache_creation_input_tokens or 0)
              + (json.message.usage.cache_read_input_tokens or 0)

            self.temp.output_tokens = json.message.usage.output_tokens or 0
          elseif json.type == "message_delta" then
            return (self.temp.input_tokens + self.temp.output_tokens + json.usage.output_tokens)
          elseif json.type == "message" then
            self.temp.input_tokens = json.usage.input_tokens
            return (json.usage.input_tokens + json.usage.output_tokens)
          end
        end
      end,

      parse_chat = function(self, args)
        local data, tools = args.data, args.tools
        local output = {}

        if self.opts.stream then
          if type(data) == "string" and string.sub(data, 1, 6) == "event:" then
            return
          end
        end

        if data and data ~= "" then
          if self.opts.stream then
            data = adapter_utils.clean_streamed_data(data)
          else
            data = data.body
          end

          local ok, json = pcall(vim.json.decode, data, { luanil = { object = true } })

          if ok and type(json) == "table" then
            if json.type == "message_start" then
              output.role = json.message.role
              output.content = ""
            elseif json.type == "content_block_start" then
              if json.content_block.type == "thinking" then
                output.reasoning = output.reasoning or {}
                output.reasoning.content = ""
              end
              if json.content_block.type == "tool_use" and tools then
                -- Ref: https://docs.anthropic.com/en/docs/build-with-claude/tool-use/overview#single-tool-example
                table.insert(tools, {
                  _index = json.index,
                  id = json.content_block.id,
                  name = json.content_block.name,
                  input = "",
                })
              end
            elseif json.type == "content_block_delta" then
              if json.delta.type == "thinking_delta" then
                output.reasoning = output.reasoning or {}
                output.reasoning.content = json.delta.thinking
              elseif json.delta.type == "signature_delta" then
                output.reasoning = output.reasoning or {}
                output.reasoning.signature = json.delta.signature
              else
                output.content = json.delta.text
                if json.delta.partial_json and tools then
                  for i, tool in ipairs(tools) do
                    if tool._index == json.index then
                      tools[i].input = tools[i].input .. json.delta.partial_json
                      break
                    end
                  end
                end
              end
            elseif json.type == "message" then
              output.role = json.role

              for i, content in ipairs(json.content) do
                if content.type == "text" then
                  output.content = (output.content or "") .. content.text
                elseif content.type == "thinking" then
                  output.reasoning = { content = content.thinking, signature = content.signature }
                elseif content.type == "tool_use" and tools then
                  table.insert(tools, {
                    _index = i,
                    id = content.id,
                    name = content.name,
                    -- Encode the input as JSON to match the partial JSON which comes encoded
                    input = vim.json.encode(content.input),
                  })
                end
              end
            end

            return {
              status = "success",
              output = output,
            }
          end
        end
      end,
    },

    tools = {
      format_calls = function(self, args)
        local formatted = {}
        for _, tool in ipairs(args.tools) do
          table.insert(formatted, {
            _index = tool._index,
            id = tool.id,
            type = "function",
            ["function"] = {
              name = tool.name,
              arguments = tool.input,
            },
          })
        end
        return formatted
      end,
    },
  },
}
