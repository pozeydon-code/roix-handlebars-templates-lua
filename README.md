# Roix Handlebars Templates Lua

Plugin de Neovim en Lua para insertar plantillas Handlebars interactivas y acelerar la creación de código React: componentes, pantallas `master`/`single`, hooks, stores y snippets de trabajo diario.

## Camino rápido

1. Instalá el plugin con `lazy.nvim`.
2. Configurá `templates_dir` apuntando a `templates/handlebars`.
3. Usá `<leader>ht` para elegir una plantilla o los comandos `:Hbs*` para flujos específicos.

```lua
{
  "pozeydon-code/roix-handlebars-templates-lua",
  name = "handlebars-templates",
  config = function()
    local plugin_dir = vim.fn.stdpath("data") .. "/lazy/roix-handlebars-templates-lua"

    require("handlebars-templates").setup({
      templates_dir = plugin_dir .. "/templates/handlebars",
      trigger_key = "<leader>ht",
      jump_key = "<C-j>",
    })
  end,
}
```

## Qué hace

| Funcionalidad                | Descripción                                                                                 |
| ---------------------------- | ------------------------------------------------------------------------------------------- |
| Selector de plantillas       | Lista las plantillas `.hbs` disponibles y pide los valores definidos en `definitions.json`. |
| Compilador Handlebars simple | Soporta variables, `#if`, `#unless`, `#each`, `contains`, `setter` y placeholders.          |
| Salto entre placeholders     | Permite navegar placeholders `{{...}}` con una tecla configurable.                          |
| State extractor              | Genera `useState` o extrae estado/setter desde contexto React.                              |
| Store generator              | Crea stores React con `useReducer`, `Context`, actions y JSDoc.                             |
| Add action                   | Inserta una action nueva dentro de un store generado previamente.                           |

> Importante: este plugin implementa un subset práctico de Handlebars. No busca reemplazar un motor Handlebars completo; está pensado para snippets y generación rápida dentro de Neovim.

## Comandos

| Comando                 | Uso                                                   |
| ----------------------- | ----------------------------------------------------- |
| `:HbsInsert <template>` | Inserta una plantilla por nombre.                     |
| `:HbsList`              | Muestra las plantillas disponibles.                   |
| `:HbsReload`            | Recarga `definitions.json`.                           |
| `:HbsCreateStore`       | Crea un store React interactivo.                      |
| `:HbsAddStoreAction`    | Agrega una action a un store existente.               |
| `:StateCreate`          | Crea `useState` o extracción desde contexto.          |
| `:StateCreateVisual`    | Reemplaza la selección visual por el estado generado. |

## Keymaps por defecto

| Tecla        | Modo          | Acción                                        |
| ------------ | ------------- | --------------------------------------------- |
| `<leader>ht` | Normal        | Abrir selector de plantillas.                 |
| `<C-j>`      | Normal/Insert | Saltar al siguiente placeholder `{{...}}`.    |
| `<leader>hs` | Normal/Visual | Crear `useState` o extracción desde contexto. |
| `<leader>hS` | Normal        | Crear store React con reducer/actions.        |
| `<leader>ha` | Normal        | Agregar action a un store existente.          |

## Plantillas incluidas

| Plantilla   | Archivo                               |
| ----------- | ------------------------------------- |
| Console log | `templates/handlebars/consoleLog.hbs` |
| Custom hook | `templates/handlebars/customHook.hbs` |
| Component   | `templates/handlebars/component.hbs`  |
| Field       | `templates/handlebars/field.hbs`      |
| Master page | `templates/handlebars/master.hbs`     |
| Single page | `templates/handlebars/single.hbs`     |
| Routes      | `templates/handlebars/routes.hbs`     |
| Store       | `templates/handlebars/store.hbs`      |
| useEffect   | `templates/handlebars/useEffect.hbs`  |

Las variables, selects y opciones múltiples se declaran en:

```text
templates/handlebars/definitions.json
```

## Configuración

```lua
require("handlebars-templates").setup({
  templates_dir = vim.fn.stdpath("config") .. "/templates/handlebars",
  trigger_key = "<leader>ht",
  jump_key = "<C-j>",
})
```

| Opción          | Default                                        | Descripción                                                       |
| --------------- | ---------------------------------------------- | ----------------------------------------------------------------- |
| `templates_dir` | `stdpath("config") .. "/templates/handlebars"` | Carpeta donde se leen las plantillas `.hbs` y `definitions.json`. |
| `trigger_key`   | `<leader>ht`                                   | Keymap para abrir el selector de plantillas.                      |
| `jump_key`      | `<C-j>`                                        | Keymap para saltar al próximo placeholder.                        |

## Desarrollo local

Si estás desarrollando desde tu configuración de Neovim, podés usar el plugin como directorio local:

```lua
return {
  dir = vim.fn.stdpath("config") .. "/lua/handlebars-templates",
  name = "handlebars-templates",
  config = function()
    require("handlebars-templates").setup({
      templates_dir = vim.fn.stdpath("config") .. "/templates/handlebars",
      trigger_key = "<leader>ht",
      jump_key = "<C-j>",
    })
  end,
  lazy = false,
}
```

## Estructura del repo

```text
lua/handlebars-templates/
  init.lua
  state-extractor.lua
templates/handlebars/
  definitions.json
  *.hbs
README.md
LICENSE
```
