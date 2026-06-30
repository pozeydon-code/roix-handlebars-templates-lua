local M = {}

-- ============================================
-- Utils: buffer / string helpers
-- ============================================
local function trim(s)
  return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function get_indent_of_line(line)
  return (line:match("^%s*") or "")
end

-- ============================================
-- Detectar hooks existentes
-- ============================================
function M.has_use_context()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  for _, line in ipairs(lines) do
    if line:match("useContext") then
      return true
    end
  end
  return false
end

-- Detectar el nombre de la variable que guarda useContext(...)
-- Ej:
--   const contexto = useContext(StoreContext)
--   const contexto = React.useContext(StoreContext)
--   const contextito = useContext(StoreContext)
--   const { x } = useContext(StoreContext)  --> (en este caso no hay variable única)
function M.get_context_var_name()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)

  for _, line in ipairs(lines) do
    -- const contextito = useContext(StoreContext)
    local var = line:match("^%s*const%s+([%w_]+)%s*=%s*useContext%s*%(")
      or line:match("^%s*const%s+([%w_]+)%s*=%s*React%.useContext%s*%(")
    if var and var ~= "" then
      return var
    end
  end

  -- Si no se detecta, usar fallback
  return "contexto"
end

-- ============================================
-- Selección visual: rango
-- ============================================
function M.get_visual_range()
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")

  if start_pos[2] > 0 and end_pos[2] > 0 then
    return {
      start_line = start_pos[2],
      end_line = end_pos[2],
    }
  end

  return nil
end

-- Obtener texto seleccionado o pedir input
function M.get_state_name(callback)
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")

  if start_pos[2] > 0 and end_pos[2] > 0 then
    local lines = vim.api.nvim_buf_get_lines(0, start_pos[2] - 1, end_pos[2], false)

    if #lines > 0 then
      local selected = ""

      if #lines == 1 then
        selected = lines[1]:sub(start_pos[3], end_pos[3])
      else
        selected = lines[1]:sub(start_pos[3])
      end

      selected = trim(selected)

      if selected ~= "" then
        callback(selected)
        return
      end
    end
  end

  M.prompt_state_name(callback)
end

-- Pedir nombre del estado
function M.prompt_state_name(callback)
  vim.ui.input({
    prompt = "Nombre del estado: ",
  }, function(input)
    input = trim(input)
    if input ~= "" then
      callback(input)
    end
  end)
end

-- Generar setter name
function M.generate_setter(state_name)
  state_name = state_name:gsub("[-_](%w)", function(c)
    return c:upper()
  end)
  local first_char = state_name:sub(1, 1):upper()
  local rest = state_name:sub(2)
  return "set" .. first_char .. rest
end

-- Selector de tipo de estado
function M.prompt_state_type(has_context, callback)
  local options = { "useState" }

  if has_context then
    table.insert(options, "contexto")
  end

  vim.ui.select(options, {
    prompt = "Tipo de estado:",
  }, function(choice)
    if choice then
      callback(choice)
    end
  end)
end

-- Selector de tipo de valor inicial para useState
function M.prompt_initial_value_type(callback)
  local options = {
    { label = "false (boolean)", value = "false" },
    { label = "true (boolean)", value = "true" },
    { label = "0 (number)", value = "0" },
    { label = '"" (string)', value = '""' },
    { label = "[] (array)", value = "[]" },
    { label = "{} (object)", value = "{}" },
    { label = "null", value = "null" },
    { label = "undefined", value = "undefined" },
    { label = "Custom...", value = "custom" },
  }

  local labels = {}
  for _, opt in ipairs(options) do
    table.insert(labels, opt.label)
  end

  vim.ui.select(labels, {
    prompt = "Valor inicial del estado:",
  }, function(choice)
    if choice then
      for _, opt in ipairs(options) do
        if opt.label == choice then
          if opt.value == "custom" then
            vim.ui.input({
              prompt = "Valor inicial personalizado: ",
            }, function(custom)
              callback(trim(custom) ~= "" and custom or "null")
            end)
          else
            callback(opt.value)
          end
          return
        end
      end
    end
  end)
end

-- Selector de qué extraer del contexto
function M.prompt_context_extract(callback)
  local options = {
    "Solo estado",
    "Solo setter",
    "Estado y setter",
  }

  vim.ui.select(options, {
    prompt = "¿Qué querés extraer del contexto?",
  }, function(choice)
    if choice then
      callback(choice)
    end
  end)
end

-- Generar código de useState
function M.generate_use_state(state_name, initial_value)
  local setter = M.generate_setter(state_name)
  return string.format("const [%s, %s] = useState(%s);", state_name, setter, initial_value)
end

-- Generar código de contexto (usando el nombre real del context variable)
function M.generate_context(context_var, state_name, extract_type)
  local setter = M.generate_setter(state_name)

  if extract_type == "Solo estado" then
    return string.format("const { %s } = %s.%s;", state_name, context_var, state_name)
  elseif extract_type == "Solo setter" then
    return string.format("const { %s } = %s.%s;", setter, context_var, state_name)
  else
    return string.format("const { %s, %s } = %s.%s;", state_name, setter, context_var, state_name)
  end
end

-- ============================================
-- Import management: asegurar useState
-- ============================================
function M.has_react_hook_import(hook_name)
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  for _, line in ipairs(lines) do
    -- import React, { useState } from "react";
    -- import { useState } from "react";
    if line:match("from%s+['\"]react['\"]") and line:match(hook_name) then
      return true
    end
  end
  return false
end

function M.ensure_react_hook_import(hook_name)
  if M.has_react_hook_import(hook_name) then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)

  for i, line in ipairs(lines) do
    -- Caso 1: import React, { ... } from "react";
    if line:match("^%s*import%s+React%s*,%s*{") and line:match("from%s+['\"]react['\"]") then
      -- ya tiene llaves, insertar hook si no está
      if not line:match(hook_name) then
        -- Insertar antes del "}"
        local replaced = line:gsub("{%s*", "{ " .. hook_name .. ", ")
        vim.api.nvim_buf_set_lines(0, i - 1, i, false, { replaced })
      end
      return
    end

    -- Caso 2: import { ... } from "react";
    if line:match("^%s*import%s*{") and line:match("from%s+['\"]react['\"]") then
      if not line:match(hook_name) then
        local replaced = line:gsub("{%s*", "{ " .. hook_name .. ", ")
        vim.api.nvim_buf_set_lines(0, i - 1, i, false, { replaced })
      end
      return
    end

    -- Caso 3: import React from "react";
    if line:match("^%s*import%s+React%s+from%s+['\"]react['\"]") then
      local replaced = line:gsub("import%s+React%s+from", "import React, { " .. hook_name .. " } from")
      vim.api.nvim_buf_set_lines(0, i - 1, i, false, { replaced })
      return
    end
  end

  -- Si no encontramos import de react, lo insertamos arriba del archivo
  vim.api.nvim_buf_set_lines(0, 0, 0, false, { "import React, { " .. hook_name .. ' } from "react";' })
end

-- ============================================
-- Insert / Replace code
-- ============================================
function M.find_insertion_point()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local last_declaration_line = 0

  for i, line in ipairs(lines) do
    if
      line:match("^%s*const%s+")
      or line:match("^%s*let%s+")
      or line:match("^%s*var%s+")
      or line:match("^%s*const%s+{.*}%s*=%s*props")
      or line:match("^%s*const%s+.*=%s*useForm")
      or line:match("^%s*const%s+.*=%s*useFormState")
      or line:match("^%s*const%s+.*=%s*useContext")
      or line:match("^%s*const%s+{.*}%s*=%s*contexto")
    then
      last_declaration_line = i
    end

    if line:match("^%s*useEffect") or line:match("^%s*return%s*%(") or line:match("^%s*//%s*useEffect") then
      break
    end
  end

  if last_declaration_line > 0 then
    return last_declaration_line
  end

  for i, line in ipairs(lines) do
    if line:match("=%s*%(") or line:match("function%s+") then
      for j = i + 1, #lines do
        if lines[j]:match("%S") then
          return j - 1
        end
      end
    end
  end

  return vim.api.nvim_win_get_cursor(0)[1]
end

-- Inserción normal (sin selección)
function M.insert_code(code)
  local line_num = M.find_insertion_point()

  local ref = vim.api.nvim_buf_get_lines(0, line_num - 1, line_num, false)
  local indent = "  "
  if #ref > 0 then
    indent = get_indent_of_line(ref[1])
    if indent == "" then
      indent = "  "
    end
  end

  vim.api.nvim_buf_set_lines(0, line_num, line_num, false, { indent .. code })
  vim.api.nvim_win_set_cursor(0, { line_num + 1, #indent })
end

-- Reemplazo cuando hay selección visual (REEMPLAZA las líneas seleccionadas)
function M.replace_selection_with_code(code)
  local range = M.get_visual_range()
  if not range then
    -- fallback normal
    M.insert_code(code)
    return
  end

  local lines = vim.api.nvim_buf_get_lines(0, range.start_line - 1, range.start_line, false)
  local indent = "  "
  if #lines > 0 then
    indent = get_indent_of_line(lines[1])
    if indent == "" then
      indent = "  "
    end
  end

  -- Reemplazar todas las líneas seleccionadas por una sola línea
  vim.api.nvim_buf_set_lines(0, range.start_line - 1, range.end_line, false, { indent .. code })

  vim.api.nvim_win_set_cursor(0, { range.start_line, #indent })
end

-- ============================================
-- Comandos principales
-- ============================================
function M.create_state(opts)
  opts = opts or {}
  local replace_on_selection = opts.replace_on_selection == true

  M.get_state_name(function(state_name)
    state_name = trim(state_name)
    if state_name == "" then
      return
    end

    local has_context = M.has_use_context()
    local context_var = M.get_context_var_name()

    M.prompt_state_type(has_context, function(state_type)
      if state_type == "useState" then
        -- ✅ asegurar import useState
        M.ensure_react_hook_import("useState")

        M.prompt_initial_value_type(function(initial_value)
          local code = M.generate_use_state(state_name, initial_value)

          if replace_on_selection then
            M.replace_selection_with_code(code)
          else
            M.insert_code(code)
          end

          vim.notify("useState creado: " .. state_name, vim.log.levels.INFO)
        end)
      elseif state_type == "contexto" then
        M.prompt_context_extract(function(extract_type)
          local code = M.generate_context(context_var, state_name, extract_type)

          if replace_on_selection then
            M.replace_selection_with_code(code)
          else
            M.insert_code(code)
          end

          vim.notify("Contexto extraído: " .. state_name .. " (desde " .. context_var .. ")", vim.log.levels.INFO)
        end)
      end
    end)
  end)
end

function M.create_state_from_selection()
  -- Salir del modo visual correctamente
  local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
  vim.api.nvim_feedkeys(esc, "x", false)

  vim.schedule(function()
    M.create_state({ replace_on_selection = true })
  end)
end

-- Setup
function M.setup()
  vim.api.nvim_create_user_command("StateCreate", function()
    M.create_state()
  end, { desc = "Crear useState o extraer del contexto" })

  vim.api.nvim_create_user_command("StateCreateVisual", function()
    M.create_state_from_selection()
  end, { desc = "Crear estado desde selección visual" })

  vim.keymap.set("n", "<leader>hs", function()
    M.create_state()
  end, { desc = "Crear useState/contexto", noremap = true, silent = true })

  vim.keymap.set("v", "<leader>hs", function()
    M.create_state_from_selection()
  end, { desc = "Crear useState/contexto desde selección", noremap = true, silent = true })
end

return M
