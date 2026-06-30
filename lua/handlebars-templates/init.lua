local M = {}

local function trim(s)
  return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function sanitize_identifier(value)
  local sanitized = trim(value):gsub("[%s%-]+", "_"):gsub("[^%w_]", "")
  if sanitized:match("^%d") then
    sanitized = "_" .. sanitized
  end
  return sanitized
end

-- Configuración por defecto
M.config = {
  templates_dir = vim.fn.stdpath("config") .. "/templates/handlebars",
  trigger_key = "<leader>ht",
  jump_key = "<C-j>",
}

-- Cache para definiciones de plantillas
M.template_definitions = {}

-- Capturar el lugar real desde donde se invocó el template.
-- Esto es importante porque vim.ui.select/input puede cambiar la ventana/buffer activo
-- antes de que termine el flujo async de preguntas.
function M.capture_insert_context()
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(win)
  local current_line = vim.api.nvim_buf_get_lines(buf, cursor[1] - 1, cursor[1], false)[1] or ""

  return {
    win = win,
    buf = buf,
    row = cursor[1],
    col = cursor[2],
    indent = current_line:match("^%s*") or "",
    current_line = current_line,
  }
end

function M.apply_base_indent(lines, indent)
  if not indent or indent == "" then
    return lines
  end

  local indented = {}
  for _, line in ipairs(lines) do
    if line:match("%S") then
      table.insert(indented, indent .. line)
    else
      table.insert(indented, line)
    end
  end

  return indented
end

-- Helpers personalizados para Handlebars
M.helpers = {
  -- Helper para verificar si un array contiene un valor
  contains = function(array, value)
    if type(array) ~= "table" then
      return false
    end
    for _, v in ipairs(array) do
      if v == value then
        return true
      end
    end
    return false
  end,

  -- Helper para generar setter de un estado
  setter = function(state_name)
    -- Convertir kebab-case o snake_case a camelCase primero
    state_name = state_name:gsub("[-_](%w)", function(c)
      return c:upper()
    end)
    local first_char = state_name:sub(1, 1):upper()
    local rest = state_name:sub(2)
    return "set" .. first_char .. rest
  end,

  -- Helper para escape de caracteres especiales
  escape = function(text)
    return text
  end,
}

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  if vim.fn.isdirectory(M.config.templates_dir) == 0 then
    vim.fn.mkdir(M.config.templates_dir, "p")
  end

  M.load_template_definitions()

  -- Cargar módulo de state-extractor
  local state_extractor_ok, state_extractor = pcall(require, "handlebars-templates.state-extractor")
  if state_extractor_ok then
    state_extractor.setup()
  else
    vim.notify("No se pudo cargar state-extractor: " .. tostring(state_extractor), vim.log.levels.WARN)
  end

  -- Comandos
  vim.api.nvim_create_user_command("HbsInsert", function(args)
    M.insert_template_interactive(args.args)
  end, {
    nargs = 1,
    complete = function()
      return M.get_templates()
    end,
    desc = "Insertar plantilla Handlebars",
  })

  vim.api.nvim_create_user_command("HbsList", function()
    M.list_templates()
  end, { desc = "Listar plantillas Handlebars" })

  vim.api.nvim_create_user_command("HbsReload", function()
    M.load_template_definitions()
    vim.notify("Plantillas recargadas", vim.log.levels.INFO)
  end, { desc = "Recargar definiciones de plantillas" })

  vim.api.nvim_create_user_command("HbsCreateStore", function()
    M.create_store_interactive()
  end, { desc = "Crear store React con reducer y actions" })

  vim.api.nvim_create_user_command("HbsAddStoreAction", function()
    M.add_store_action_interactive()
  end, { desc = "Agregar action a un store React existente" })

  -- Mapeos
  vim.keymap.set("n", M.config.trigger_key, M.show_template_picker, { desc = "Seleccionar plantilla Handlebars" })

  vim.keymap.set("n", "<leader>hS", M.create_store_interactive, { desc = "Crear store React con reducer/actions" })

  vim.keymap.set("n", "<leader>ha", M.add_store_action_interactive, { desc = "Agregar action a store React" })

  vim.keymap.set("i", M.config.jump_key, M.jump_to_next_placeholder, { desc = "Saltar al siguiente placeholder" })

  vim.keymap.set("n", M.config.jump_key, M.jump_to_next_placeholder, { desc = "Saltar al siguiente placeholder" })
end

-- Cargar definiciones de plantillas
function M.load_template_definitions()
  M.template_definitions = {}
  local def_path = M.config.templates_dir .. "/definitions.json"

  if vim.fn.filereadable(def_path) == 1 then
    local content = table.concat(vim.fn.readfile(def_path), "\n")
    local ok, definitions = pcall(vim.json.decode, content)

    if ok and definitions then
      for _, def in ipairs(definitions) do
        M.template_definitions[def.name] = def
      end
    else
      vim.notify("Error al cargar definitions.json", vim.log.levels.ERROR)
    end
  end
end

-- Compilador de Handlebars en Lua (mejorado)
function M.compile_handlebars(template_str, context, depth)
  depth = depth or 0
  if depth > 10 then
    return template_str -- Prevenir recursión infinita
  end

  local output = template_str

  -- Procesar {{#each array}}...{{/each}} PRIMERO (más específico)
  while true do
    local changed = false
    output = output:gsub("{{#each%s+([%w_]+)}}(.-){{/each}}", function(var, content)
      changed = true
      local array = context[var]
      if type(array) ~= "table" or #array == 0 then
        return ""
      end

      local result = {}
      for i, item in ipairs(array) do
        local item_context = vim.tbl_extend("force", context, {
          this = item,
          ["@index"] = i - 1,
          ["@first"] = i == 1,
          ["@last"] = i == #array,
        })
        local compiled = M.compile_handlebars(content, item_context, depth + 1)
        table.insert(result, compiled)
      end
      return table.concat(result, "")
    end)
    if not changed then
      break
    end
  end

  -- Procesar {{#unless @last}}...{{/unless}} y {{#unless variable}}...{{/unless}}
  while true do
    local changed = false
    output = output:gsub("{{#unless%s+(@?[%w_]+)}}(.-){{/unless}}", function(var, content)
      changed = true
      local value = context[var]
      if not value or value == false or value == "" or (type(value) == "table" and #value == 0) then
        return M.compile_handlebars(content, context, depth + 1)
      end
      return ""
    end)
    if not changed then
      break
    end
  end

  -- Procesar {{#if variable}}...{{/if}}
  while true do
    local changed = false
    output = output:gsub("{{#if%s+([%w_]+)}}(.-){{/if}}", function(var, content)
      changed = true
      local value = context[var]
      if
        value
        and ((type(value) == "table" and #value > 0) or (type(value) ~= "table" and value ~= false and value ~= ""))
      then
        return M.compile_handlebars(content, context, depth + 1)
      end
      return ""
    end)
    if not changed then
      break
    end
  end

  -- Procesar {{#contains array "value"}}...{{/contains}}
  output = output:gsub('{{#contains%s+([%w_]+)%s+"([^"]+)"}}(.-){{/contains}}', function(var, value, content)
    local array = context[var]
    if M.helpers.contains(array, value) then
      return M.compile_handlebars(content, context, depth + 1)
    end
    return ""
  end)

  -- Procesar helpers
  output = output:gsub("{{setter%s+([%w_%-]+)}}", function(var)
    return M.helpers.setter(context[var] or var)
  end)

  output = output:gsub('{{escape%s+"([^"]+)"}}', function(text)
    return text
  end)

  -- Procesar variables especiales
  output = output:gsub("{{@last}}", function()
    return tostring(context["@last"] or false)
  end)

  output = output:gsub("{{@first}}", function()
    return tostring(context["@first"] or false)
  end)

  output = output:gsub("{{@index}}", function()
    return tostring(context["@index"] or 0)
  end)

  -- Procesar {{this}}
  output = output:gsub("{{this}}", function()
    return tostring(context.this or "")
  end)

  -- Procesar variables simples {{variable}} o {{variable-with-dash}}
  output = output:gsub("{{([%w_%-]+)}}", function(var)
    local value = context[var]
    if value == nil then
      return "{{" .. var .. "}}" -- Mantener como placeholder
    end
    if type(value) == "table" then
      return ""
    end
    return tostring(value)
  end)

  return output
end

-- Solicitar input del usuario para una variable
function M.prompt_variable(var_def, callback)
  if var_def.type == "string" then
    vim.ui.input({
      prompt = (var_def.description or var_def.name) .. ": ",
      default = var_def.default or "",
    }, function(input)
      callback(input or "")
    end)
  elseif var_def.type == "select" then
    if var_def.multiple then
      M.prompt_multiple_select(var_def, callback)
    else
      local options = {}
      for _, opt in ipairs(var_def.options) do
        table.insert(options, opt.label or opt.value)
      end

      vim.ui.select(options, {
        prompt = (var_def.description or var_def.name) .. ":",
        format_item = function(item)
          return item
        end,
      }, function(choice)
        if choice then
          for _, opt in ipairs(var_def.options) do
            if (opt.label or opt.value) == choice then
              callback(opt.value)
              return
            end
          end
        end
        callback("")
      end)
    end
  else
    callback("")
  end
end

-- Selector múltiple
function M.prompt_multiple_select(var_def, callback)
  local selected = {}

  for _, opt in ipairs(var_def.options) do
    if opt.checked then
      table.insert(selected, opt.value)
    end
  end

  local buf = vim.api.nvim_create_buf(false, true)
  local lines = {}
  local options_map = {}

  table.insert(lines, "Selecciona opciones (Espacio=marcar, Enter=confirmar, q=cancelar):")
  table.insert(lines, "")

  for i, opt in ipairs(var_def.options) do
    local checked = opt.checked and "[x]" or "[ ]"
    local line = string.format("%s %s", checked, opt.label or opt.value)
    table.insert(lines, line)
    options_map[#lines] = i
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, "modifiable", false)

  local width = 60
  local height = math.min(#lines, 15)
  local opts = {
    relative = "editor",
    width = width,
    height = height,
    col = (vim.o.columns - width) / 2,
    row = (vim.o.lines - height) / 2,
    style = "minimal",
    border = "rounded",
  }

  local win = vim.api.nvim_open_win(buf, true, opts)
  vim.api.nvim_win_set_cursor(win, { 3, 0 })
  local closed = false

  local function close_picker(result)
    if closed then
      return
    end

    closed = true

    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end

    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end

    callback(result)
  end

  local function update_display()
    vim.api.nvim_buf_set_option(buf, "modifiable", true)
    local current_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

    for line_num, opt_index in pairs(options_map) do
      local opt = var_def.options[opt_index]
      local is_selected = vim.tbl_contains(selected, opt.value)
      local checked = is_selected and "[x]" or "[ ]"
      current_lines[line_num] = string.format("%s %s", checked, opt.label or opt.value)
    end

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, current_lines)
    vim.api.nvim_buf_set_option(buf, "modifiable", false)
  end

  vim.keymap.set("n", "<Space>", function()
    local cursor = vim.api.nvim_win_get_cursor(win)
    local line_num = cursor[1]
    local opt_index = options_map[line_num]

    if opt_index then
      local opt = var_def.options[opt_index]
      local idx = nil

      for i, val in ipairs(selected) do
        if val == opt.value then
          idx = i
          break
        end
      end

      if idx then
        table.remove(selected, idx)
      else
        table.insert(selected, opt.value)
      end

      update_display()
    end
  end, { buffer = buf, nowait = true })

  vim.keymap.set("n", "<CR>", function()
    close_picker(selected)
  end, { buffer = buf, nowait = true })

  vim.keymap.set("n", "q", function()
    close_picker({})
  end, { buffer = buf, nowait = true })

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      if not closed then
        close_picker({})
      end
    end,
  })
end

-- Insertar plantilla de forma interactiva
function M.insert_template_interactive(template_name, insert_context)
  insert_context = insert_context or M.capture_insert_context()
  local template_path = M.config.templates_dir .. "/" .. template_name .. ".hbs"

  if vim.fn.filereadable(template_path) == 0 then
    vim.notify("Plantilla no encontrada: " .. template_name, vim.log.levels.ERROR)
    return
  end

  local definition = M.template_definitions[template_name]

  if not definition or not definition.variables or #definition.variables == 0 then
    M.insert_template_simple(template_name, insert_context)
    return
  end

  local values = {}
  local var_index = 1

  local function process_next_variable()
    if var_index > #definition.variables then
      M.insert_template_with_values(template_name, values, insert_context)
      return
    end

    local var_def = definition.variables[var_index]
    M.prompt_variable(var_def, function(value)
      values[var_def.name] = value
      var_index = var_index + 1
      vim.schedule(function()
        process_next_variable()
      end)
    end)
  end

  process_next_variable()
end

-- Insertar plantilla con valores
function M.insert_template_with_values(template_name, values, insert_context)
  insert_context = insert_context or M.capture_insert_context()
  local template_path = M.config.templates_dir .. "/" .. template_name .. ".hbs"
  local template_content = table.concat(vim.fn.readfile(template_path), "\n")
  local filepath = vim.api.nvim_buf_is_valid(insert_context.buf) and vim.api.nvim_buf_get_name(insert_context.buf) or ""

  -- Agregar variables del sistema
  local context = vim.tbl_extend("force", {
    filename = vim.fn.fnamemodify(filepath, ":t:r"),
    file = vim.fn.fnamemodify(filepath, ":t"),
    filepath = filepath,
    date = os.date("%Y-%m-%d"),
    time = os.date("%H:%M:%S"),
    datetime = os.date("%Y-%m-%d %H:%M:%S"),
    year = os.date("%Y"),
    author = vim.fn.system("git config user.name"):gsub("\n", "") or os.getenv("USER"),
    email = vim.fn.system("git config user.email"):gsub("\n", "") or "",
  }, values)

  -- Compilar la plantilla
  local compiled = M.compile_handlebars(template_content, context)

  -- Dividir en líneas
  local lines = vim.split(compiled, "\n")
  lines = M.apply_base_indent(lines, insert_context.indent)

  if not vim.api.nvim_buf_is_valid(insert_context.buf) then
    vim.notify("No se pudo insertar la plantilla: el buffer original ya no existe", vim.log.levels.ERROR)
    return
  end

  -- Insertar en el buffer original. Si la línea actual está vacía o solo tiene indentación,
  -- se reemplaza para no dejar una línea basura antes del template.
  local line_count = vim.api.nvim_buf_line_count(insert_context.buf)
  local target_row = math.min(insert_context.row, line_count)
  local start_row = target_row - 1
  local end_row = insert_context.current_line:match("^%s*$") and target_row or target_row - 1
  vim.api.nvim_buf_set_lines(insert_context.buf, start_row, end_row, false, lines)

  if vim.api.nvim_win_is_valid(insert_context.win) then
    pcall(vim.api.nvim_set_current_win, insert_context.win)
    pcall(vim.api.nvim_win_set_cursor, insert_context.win, {
      target_row,
      math.min(insert_context.col, #(lines[1] or "")),
    })
  end

  vim.schedule(function()
    if vim.api.nvim_win_is_valid(insert_context.win) then
      pcall(vim.api.nvim_set_current_win, insert_context.win)
      M.jump_to_next_placeholder({
        start_line = target_row,
        end_line = target_row + #lines - 1,
      })
    end
  end)
end

-- Insertar plantilla simple
function M.insert_template_simple(template_name, insert_context)
  M.insert_template_with_values(template_name, {}, insert_context)
end

-- ============================================
-- Generador especializado: React Store
-- ============================================
function M.default_value_for_type(value_type)
  local defaults = {
    boolean = "false",
    string = '""',
    number = "0",
    array = "[]",
    object = "{}",
    any = "null",
  }

  return defaults[value_type] or "null"
end

function M.jsdoc_payload_type(value_type)
  local types = {
    boolean = "boolean",
    string = "string",
    number = "number",
    array = "Array<any>",
    object = "Object",
    any = "any",
  }

  return types[value_type] or "any"
end

function M.prompt_store_action(actions, callback)
  vim.ui.input({
    prompt = "Nombre de action (vacío para terminar): ",
  }, function(action_name)
    action_name = sanitize_identifier(action_name)

    if action_name == "" then
      callback(actions)
      return
    end

    local types = { "boolean", "string", "number", "array", "object", "any" }
    vim.ui.select(types, {
      prompt = "Tipo de estado para " .. action_name .. ":",
    }, function(value_type)
      if not value_type then
        callback(actions)
        return
      end

      vim.ui.input({
        prompt = "Valor inicial para " .. action_name .. ": ",
        default = M.default_value_for_type(value_type),
      }, function(initial_value)
        initial_value = trim(initial_value)
        if initial_value == "" then
          initial_value = M.default_value_for_type(value_type)
        end

        vim.ui.input({
          prompt = "Payload por defecto para " .. action_name .. " (vacío = sin default): ",
        }, function(default_payload)
          table.insert(actions, {
            name = action_name,
            type = value_type,
            initial_value = initial_value,
            default_payload = trim(default_payload),
          })

          vim.schedule(function()
            M.prompt_store_action(actions, callback)
          end)
        end)
      end)
    end)
  end)
end

function M.generate_store_code(store_name, actions)
  local lines = {}
  local function add(line)
    table.insert(lines, line or "")
  end

  add('import React, { useReducer, createContext, useContext, useMemo } from "react";')
  add("")
  add("/**")
  add(" * @typedef {Object} " .. store_name .. "State")
  for _, action in ipairs(actions) do
    add(" * @property {" .. action.type .. "} [" .. action.name .. "]")
  end
  add(" */")
  add("")
  add("/**")
  add(" * @typedef {Object} " .. store_name .. "Actions")
  for _, action in ipairs(actions) do
    add(" * @property {\"" .. action.name .. "\"} " .. action.name)
  end
  add(" */")
  add("")
  add("/** @type {" .. store_name .. "Actions} */")
  add("const " .. store_name .. "Actions = {")
  for _, action in ipairs(actions) do
    add("  " .. action.name .. ': "' .. action.name .. '",')
  end
  add("};")
  add("")
  add("const initialState = {")
  for _, action in ipairs(actions) do
    add("  " .. action.name .. ": " .. action.initial_value .. ",")
  end
  add("};")
  add("")
  add("/**")
  add(" * @typedef {Object} Action")
  add(" * @property {string} type")
  add(" * @property {any} [payload]")
  add(" */")
  add("")
  add("/**")
  add(" * @param {" .. store_name .. "State} state")
  add(" * @param {Action} action")
  add(" * @returns {" .. store_name .. "State}")
  add(" */")
  add("const " .. store_name .. "Reducer = (state, action) => {")
  add("  const { type, payload } = action;")
  add("  switch (type) {")
  for _, action in ipairs(actions) do
    add("    case " .. store_name .. "Actions." .. action.name .. ":")
    add("      return { ...state, " .. action.name .. ": payload };")
  end
  add("    default:")
  add("      return state;")
  add("  }")
  add("};")
  add("")
  add("const " .. store_name .. "Context = createContext();")
  add("")
  add("/**")
  add(" * @typedef {Object} StoreContextValue")
  add(" * @property {" .. store_name .. "State} state")
  add(" * @property {Object} actions")
  for _, action in ipairs(actions) do
    add(" * @property {(payload: " .. M.jsdoc_payload_type(action.type) .. ") => void} actions." .. action.name)
  end
  add(" */")
  add("")
  add("/**")
  add(" * @param {Object} props")
  add(" * @param {React.ReactNode} props.children")
  add(" * @param {Partial<" .. store_name .. "State>} [props]")
  add(" * @returns {JSX.Element}")
  add(" */")
  add("const " .. store_name .. "Provider = ({ children, ...props }) => {")
  add("  const [state, dispatch] = useReducer(" .. store_name .. "Reducer, { ...initialState, ...props });")
  add("")
  add("  const actions = useMemo(")
  add("    () => ({")
  for _, action in ipairs(actions) do
    local payload = "payload"
    if action.default_payload and action.default_payload ~= "" then
      payload = "payload = " .. action.default_payload
    end
    add("      " .. action.name .. ": (" .. payload .. ") => dispatch({ type: " .. store_name .. "Actions." .. action.name .. ", payload }),")
  end
  add("    }),")
  add("    [],")
  add("  );")
  add("")
  add("  return <" .. store_name .. "Context.Provider value={{ state, actions }}>{children}</" .. store_name .. "Context.Provider>;")
  add("};")
  add("")
  add("/**")
  add(" * @returns {StoreContextValue}")
  add(" */")
  add("const use" .. store_name .. "Store = () => {")
  add("  const context = useContext(" .. store_name .. "Context);")
  add("  if (!context) {")
  add('    throw new Error("Se necesita ' .. store_name .. 'Provider");')
  add("  }")
  add("  return context;")
  add("};")
  add("")
  add("export { " .. store_name .. "Provider, use" .. store_name .. "Store };")

  return table.concat(lines, "\n")
end

function M.insert_generated_store(store_name, actions, insert_context)
  local compiled = M.generate_store_code(store_name, actions)
  local lines = vim.split(compiled, "\n")
  lines = M.apply_base_indent(lines, insert_context.indent)

  if not vim.api.nvim_buf_is_valid(insert_context.buf) then
    vim.notify("No se pudo insertar el store: el buffer original ya no existe", vim.log.levels.ERROR)
    return
  end

  local line_count = vim.api.nvim_buf_line_count(insert_context.buf)
  local target_row = math.min(insert_context.row, line_count)
  local start_row = target_row - 1
  local end_row = insert_context.current_line:match("^%s*$") and target_row or target_row - 1
  vim.api.nvim_buf_set_lines(insert_context.buf, start_row, end_row, false, lines)

  if vim.api.nvim_win_is_valid(insert_context.win) then
    pcall(vim.api.nvim_set_current_win, insert_context.win)
    pcall(vim.api.nvim_win_set_cursor, insert_context.win, { target_row, 0 })
  end
end

function M.create_store_interactive()
  local insert_context = M.capture_insert_context()

  vim.ui.input({
    prompt = "Nombre del store: ",
    default = vim.fn.expand("%:t:r"),
  }, function(store_name)
    store_name = sanitize_identifier(store_name)
    if store_name == "" then
      vim.notify("Nombre de store requerido", vim.log.levels.WARN)
      return
    end

    M.prompt_store_action({}, function(actions)
      M.insert_generated_store(store_name, actions, insert_context)
      vim.notify("Store creado: " .. store_name .. " (" .. #actions .. " actions)", vim.log.levels.INFO)
    end)
  end)
end

function M.detect_store_name(bufnr)
  bufnr = bufnr or 0
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  for _, line in ipairs(lines) do
    local store_name = line:match("^%s*const%s+([%w_]+)Actions%s*=%s*{")
      or line:match("^%s*const%s+([%w_]+)Reducer%s*=")
      or line:match("^%s*const%s+([%w_]+)Context%s*=%s*createContext")

    if store_name and store_name ~= "" then
      return store_name
    end
  end

  return nil
end

function M.store_has_action(store_name, action_name, bufnr)
  bufnr = bufnr or 0
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local in_actions = false

  for _, line in ipairs(lines) do
    if line:match("^%s*const%s+" .. store_name .. "Actions%s*=%s*{") then
      in_actions = true
    elseif in_actions and line:match("^%s*};") then
      return false
    elseif in_actions and line:match("^%s*" .. action_name .. "%s*:") then
      return true
    end
  end

  return false
end

function M.insert_before_line(bufnr, line_num, new_lines)
  vim.api.nvim_buf_set_lines(bufnr or 0, line_num - 1, line_num - 1, false, new_lines)
end

function M.find_jsdoc_end_after(lines, start_pattern)
  local inside = false
  for i, line in ipairs(lines) do
    if line:match(start_pattern) then
      inside = true
    elseif inside and line:match("^%s*%*/") then
      return i
    end
  end
  return nil
end

function M.find_object_end_after(lines, start_pattern)
  local inside = false
  for i, line in ipairs(lines) do
    if line:match(start_pattern) then
      inside = true
    elseif inside and line:match("^%s*};") then
      return i
    end
  end
  return nil
end

function M.find_switch_default(lines, store_name)
  local inside_reducer = false
  for i, line in ipairs(lines) do
    if line:match("^%s*const%s+" .. store_name .. "Reducer%s*=") then
      inside_reducer = true
    elseif inside_reducer and line:match("^%s*default%s*:") then
      return i
    elseif inside_reducer and line:match("^};") then
      return nil
    end
  end
  return nil
end

function M.find_usememo_actions_end(lines)
  local inside_usememo = false
  local inside_object = false

  for i, line in ipairs(lines) do
    if line:match("^%s*const%s+actions%s*=%s*useMemo%(") then
      inside_usememo = true
    elseif inside_usememo and line:match("^%s*%(%)%s*=>%s*%(%{") then
      inside_object = true
    elseif inside_usememo and inside_object and line:match("^%s*}%),") then
      return i
    elseif inside_usememo and line:match("^%s*%);") then
      return nil
    end
  end

  return nil
end

function M.prompt_one_store_action(callback)
  vim.ui.input({
    prompt = "Nombre de action: ",
  }, function(action_name)
    action_name = sanitize_identifier(action_name)
    if action_name == "" then
      vim.notify("Nombre de action requerido", vim.log.levels.WARN)
      return
    end

    local types = { "boolean", "string", "number", "array", "object", "any" }
    vim.ui.select(types, {
      prompt = "Tipo de estado para " .. action_name .. ":",
    }, function(value_type)
      if not value_type then
        return
      end

      vim.ui.input({
        prompt = "Valor inicial para " .. action_name .. ": ",
        default = M.default_value_for_type(value_type),
      }, function(initial_value)
        initial_value = trim(initial_value)
        if initial_value == "" then
          initial_value = M.default_value_for_type(value_type)
        end

        vim.ui.input({
          prompt = "Payload por defecto para " .. action_name .. " (vacío = sin default): ",
        }, function(default_payload)
          callback({
            name = action_name,
            type = value_type,
            initial_value = initial_value,
            default_payload = trim(default_payload),
          })
        end)
      end)
    end)
  end)
end

function M.apply_store_action(store_name, action, bufnr)
  bufnr = bufnr or 0

  if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
    vim.notify("No se pudo agregar la action: el buffer original ya no existe", vim.log.levels.ERROR)
    return false
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  if M.store_has_action(store_name, action.name, bufnr) then
    vim.notify("La action ya existe: " .. action.name, vim.log.levels.WARN)
    return false
  end

  local edits = {
    {
      name = "typedef de state " .. store_name .. "State",
      line = M.find_jsdoc_end_after(lines, "@typedef%s+{Object}%s+" .. store_name .. "State"),
      text = { " * @property {" .. action.type .. "} [" .. action.name .. "]" },
    },
    {
      name = "typedef de actions " .. store_name .. "Actions",
      line = M.find_jsdoc_end_after(lines, "@typedef%s+{Object}%s+" .. store_name .. "Actions"),
      text = { " * @property {\"" .. action.name .. "\"} " .. action.name },
    },
    {
      name = "objeto " .. store_name .. "Actions",
      line = M.find_object_end_after(lines, "^%s*const%s+" .. store_name .. "Actions%s*=%s*{"),
      text = { "  " .. action.name .. ': "' .. action.name .. '",' },
    },
    {
      name = "objeto initialState",
      line = M.find_object_end_after(lines, "^%s*const%s+initialState%s*=%s*{"),
      text = { "  " .. action.name .. ": " .. action.initial_value .. "," },
    },
    {
      name = "default del switch en " .. store_name .. "Reducer",
      line = M.find_switch_default(lines, store_name),
      text = {
        "    case " .. store_name .. "Actions." .. action.name .. ":",
        "      return { ...state, " .. action.name .. ": payload };",
      },
    },
    {
      name = "typedef StoreContextValue",
      line = M.find_jsdoc_end_after(lines, "@typedef%s+{Object}%s+StoreContextValue"),
      text = { " * @property {(payload: " .. M.jsdoc_payload_type(action.type) .. ") => void} actions." .. action.name },
    },
    {
      name = "objeto actions dentro de useMemo",
      line = M.find_usememo_actions_end(lines),
      text = {
        "      "
          .. action.name
          .. ": ("
          .. (action.default_payload ~= "" and ("payload = " .. action.default_payload) or "payload")
          .. ") => dispatch({ type: "
          .. store_name
          .. "Actions."
          .. action.name
          .. ", payload }),",
      },
    },
  }

  for _, edit in ipairs(edits) do
    if not edit.line then
      vim.notify("No se encontró el bloque requerido: " .. edit.name, vim.log.levels.ERROR)
      return false
    end
  end

  table.sort(edits, function(a, b)
    return a.line > b.line
  end)

  for _, edit in ipairs(edits) do
    M.insert_before_line(bufnr, edit.line, edit.text)
  end

  return true
end

function M.add_store_action_interactive()
  local bufnr = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  local store_name = M.detect_store_name(bufnr)
  if not store_name then
    vim.notify("No pude detectar un store generado en este archivo", vim.log.levels.ERROR)
    return
  end

  M.prompt_one_store_action(function(action)
    if M.apply_store_action(store_name, action, bufnr) then
      if vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_set_current_win, win)
      end
      vim.notify("Action agregada a " .. store_name .. ": " .. action.name, vim.log.levels.INFO)
    end
  end)
end

-- Saltar al siguiente placeholder
function M.jump_to_next_placeholder(range)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line_num = cursor[1]
  local col = cursor[2]
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local start_line = range and range.start_line or line_num
  local end_line = range and range.end_line or #lines

  if range then
    line_num = start_line
    col = 0
  end

  local current_line = lines[line_num]
  if current_line and line_num >= start_line and line_num <= end_line then
    local match_start, match_end = current_line:find("{{[^}]-}}", col + 1)
    if match_start then
      vim.api.nvim_win_set_cursor(0, { line_num, match_start - 1 })
      vim.cmd("normal! v" .. (match_end - match_start + 1) .. "l")
      return true
    end
  end

  for i = math.max(line_num + 1, start_line), math.min(end_line, #lines) do
    local match_start, match_end = lines[i]:find("{{[^}]-}}")
    if match_start then
      vim.api.nvim_win_set_cursor(0, { i, match_start - 1 })
      vim.cmd("normal! v" .. (match_end - match_start + 1) .. "l")
      return true
    end
  end

  return false
end

-- Obtener lista de plantillas
function M.get_templates()
  local templates = {}
  local dir = M.config.templates_dir

  if vim.fn.isdirectory(dir) == 0 then
    return templates
  end

  local files = vim.fn.globpath(dir, "*.hbs", false, true)
  for _, file in ipairs(files) do
    local name = vim.fn.fnamemodify(file, ":t:r")
    table.insert(templates, name)
  end

  table.sort(templates)
  return templates
end

-- Selector interactivo
function M.show_template_picker()
  local insert_context = M.capture_insert_context()
  local templates = M.get_templates()

  if #templates == 0 then
    vim.notify("No hay plantillas disponibles", vim.log.levels.WARN)
    return
  end

  vim.ui.select(templates, {
    prompt = "Selecciona una plantilla Handlebars:",
    format_item = function(item)
      local def = M.template_definitions[item]
      if def and def.description then
        return "📄 " .. item .. " - " .. def.description
      end
      return "📄 " .. item
    end,
  }, function(choice)
    if choice then
      M.insert_template_interactive(choice, insert_context)
    end
  end)
end

-- Listar plantillas
function M.list_templates()
  local templates = M.get_templates()

  if #templates == 0 then
    vim.notify("No hay plantillas disponibles", vim.log.levels.WARN)
    return
  end

  local lines = { "Plantillas disponibles:", "" }
  for _, template in ipairs(templates) do
    local def = M.template_definitions[template]
    if def then
      table.insert(lines, string.format("  • %s - %s", template, def.description or ""))
    else
      table.insert(lines, "  • " .. template)
    end
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  local width = 60
  local height = math.min(#lines, 20)
  local opts = {
    relative = "editor",
    width = width,
    height = height,
    col = (vim.o.columns - width) / 2,
    row = (vim.o.lines - height) / 2,
    style = "minimal",
    border = "rounded",
  }

  vim.api.nvim_open_win(buf, true, opts)
  vim.api.nvim_buf_set_keymap(buf, "n", "q", ":close<CR>", { noremap = true, silent = true })
end

return M
