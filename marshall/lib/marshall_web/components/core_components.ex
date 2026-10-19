defmodule MarshallWeb.CoreComponents do
  @moduledoc """
  Core UI components for the Monospace Web presentation (ADR-0161).

  Every component emits semantic HTML that the hand-written stylesheet in
  `assets/css` places on the character grid. There are no utility classes:
  layout comes from elements, a few helper classes (`stack`, `row`, `grid`,
  `tree`, `width-min`, `width-auto`, `muted`, `inverse`) and the four
  presentation tokens. Icons are text glyphs (`glyph/1`).
  """
  use Phoenix.Component
  use Gettext, backend: MarshallWeb.Gettext

  alias Phoenix.LiveView.JS

  @glyphs %{
    "arrow_up_right" => "↗",
    "arrow_left" => "←",
    "arrow_right" => "→",
    "arrow_up" => "↑",
    "arrow_down" => "↓",
    "return" => "↩",
    "refresh" => "↻",
    "check" => "■",
    "cross" => "×",
    "bullet" => "●",
    "circle" => "○",
    "square" => "□",
    "diamond" => "◆",
    "caret_down" => "▾",
    "caret_right" => "▸",
    "triangle_right" => "▶",
    "triangle_down" => "▼",
    "menu" => "≡",
    "plus" => "+",
    "minus" => "−",
    "bang" => "!",
    "info" => "i",
    "search" => "/",
    "copy" => "⎘",
    "home" => "⌂",
    "star" => "*"
  }

  @doc """
  Renders a text glyph. Glyphs are decorative unless `label` names them.

  Every glyph is a code point JetBrains Mono renders as one cell; see
  `assets/css/components.css` for `.glyph`.
  """
  attr :name, :string, required: true, values: Map.keys(@glyphs)
  attr :label, :string, default: nil
  attr :class, :any, default: nil

  @spec glyph(map()) :: Phoenix.LiveView.Rendered.t()
  def glyph(assigns) do
    assigns = assign(assigns, :char, Map.fetch!(@glyphs, assigns.name))

    ~H"""
    <span class={["glyph", @class]} aria-hidden={is_nil(@label) && "true"} aria-label={@label}>{@char}</span>
    """
  end

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash
        id="welcome-back"
        kind={:info}
        phx-mounted={show("#welcome-back") |> JS.remove_attribute("hidden")}
        hidden
      >
        Welcome Back!
      </.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class="overalls-toast"
      {@rest}
    >
      <div class="flash" data-kind={@kind}>
        <div>
          <p>
            <span class="flash-tag">[{@kind}]</span>
            <strong :if={@title}>{@title}</strong>
          </p>
          <p>{msg}</p>
        </div>
        <button type="button" aria-label={dgettext("shared", "close")}>×</button>
      </div>
    </div>
    """
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  ## Examples

  ```heex
  <.input field={@form[:email]} type="email" />
  <.input name="my-input" errors={["oh no!"]} />
  ```
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :hint, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :any, default: nil, doc: "the input error class to use over defaults"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="field inline">
      <label for={@id}>
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <input
          type="checkbox"
          id={@id}
          name={@name}
          value="true"
          checked={@checked}
          class={[@class, @errors != [] && (@error_class || "invalid")]}
          {@rest}
        />
        <span>{@label}</span>
      </label>
      <p :if={@hint} class="hint">{@hint}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="field">
      <label for={@id}>
        <span :if={@label} class="field-label">{@label}</span>
        <span class="select">
          <select
            id={@id}
            name={@name}
            class={[@class, @errors != [] && (@error_class || "invalid")]}
            multiple={@multiple}
            {@rest}
          >
            <option :if={@prompt} value="">{@prompt}</option>
            {Phoenix.HTML.Form.options_for_select(@options, @value)}
          </select>
        </span>
      </label>
      <p :if={@hint} class="hint">{@hint}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="field">
      <label for={@id}>
        <span :if={@label} class="field-label">{@label}</span>
        <textarea
          id={@id}
          name={@name}
          class={[@class, @errors != [] && (@error_class || "invalid")]}
          {@rest}
        >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <p :if={@hint} class="hint">{@hint}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div class="field">
      <label for={@id}>
        <span :if={@label} class="field-label">{@label}</span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={[@class, @errors != [] && (@error_class || "invalid")]}
          {@rest}
        />
      </label>
      <p :if={@hint} class="hint">{@hint}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  @doc "Renders a form error line. The leading `!` is supplied by the stylesheet."
  slot :inner_block, required: true

  def error(assigns) do
    ~H"""
    <p class="error" role="alert">{render_slot(@inner_block)}</p>
    """
  end

  @doc """
  Renders a table with generic styling.

  Columns declare `width="min"` to shrink to content or `width="auto"` to take
  the remaining width (at most one column should grow), and `num` for
  right-aligned numbers.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id" width="min">{user.id}</:col>
        <:col :let={user} label="username" width="auto">{user.username}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"
  attr :caption, :string, default: nil

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
    attr :width, :string, values: ~w(min auto)
    attr :num, :boolean
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <div class="table-flow">
      <table>
        <caption :if={@caption} class="sr-only">{@caption}</caption>
        <thead>
          <tr>
            <th :for={col <- @col} class={[col[:width] && "width-#{col[:width]}", col[:num] && "num"]}>
              {col[:label]}
            </th>
            <th :if={@action != []} class="width-min">
              <span class="sr-only">{dgettext("shared", "Actions")}</span>
            </th>
          </tr>
        </thead>
        <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
          <tr :for={row <- @rows} id={@row_id && @row_id.(row)}>
            <td
              :for={col <- @col}
              phx-click={@row_click && @row_click.(row)}
              class={[col[:num] && "num"]}
            >
              {render_slot(col, @row_item.(row))}
            </td>
            <td :if={@action != []} class="width-min">
              <%= for action <- @action do %>
                {render_slot(action, @row_item.(row))}
              <% end %>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  @doc """
  Renders a key/value list.

  ## Examples

      <.kv>
        <:item title="Title">{@post.title}</:item>
        <:item title="Views">{@post.views}</:item>
      </.kv>
  """
  attr :id, :string, default: nil
  attr :stacked, :boolean, default: false

  slot :item, required: true do
    attr :title, :string, required: true
  end

  def kv(assigns) do
    ~H"""
    <dl id={@id} class={["kv", @stacked && "stacked"]}>
      <div :for={item <- @item}>
        <dt>{item.title}</dt>
        <dd>{render_slot(item)}</dd>
      </div>
    </dl>
    """
  end

  @doc """
  Renders a native `<dialog>` with a heading and an action row. The caller
  opens and closes it through its id; JavaScript hooks keep their ids.
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :describedby, :string, default: nil
  attr :rest, :global
  slot :inner_block, required: true
  slot :actions

  def dialog(assigns) do
    ~H"""
    <dialog id={@id} aria-labelledby={@id <> "-title"} aria-describedby={@describedby} {@rest}>
      <h2 id={@id <> "-title"}>{@title}</h2>
      {render_slot(@inner_block)}
      <div :if={@actions != []} class="dialog-actions">{render_slot(@actions)}</div>
    </dialog>
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector), do: JS.show(js, to: selector)

  def hide(js \\ %JS{}, selector), do: JS.hide(js, to: selector)

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(MarshallWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(MarshallWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
