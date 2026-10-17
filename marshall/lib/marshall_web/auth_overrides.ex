defmodule MarshallWeb.AuthOverrides do
  @moduledoc """
  AshAuthentication presentation overrides for the Monospace Web design.
  Every class the magic-link sign-in path renders is replaced so no utility
  framework class reaches the page (ADR-0161).
  """
  use AshAuthentication.Phoenix.Overrides

  @magic_link_request_feedback "Check your email for a sign-in link. Your account will be created automatically when you sign in."

  @spec magic_link_request_feedback() :: String.t()
  def magic_link_request_feedback, do: @magic_link_request_feedback

  alias AshAuthentication.Phoenix.{
    Components,
    ConfirmLive,
    MagicSignInLive,
    SignInLive,
    SignOutLive
  }

  override SignInLive do
    set :root_class, "auth-shell"
  end

  override SignOutLive do
    set :root_class, "auth-shell"
  end

  override MagicSignInLive do
    set :root_class, "auth-shell"
  end

  override ConfirmLive do
    set :root_class, "auth-shell"
  end

  override Components.Banner do
    set :root_class, "auth-banner"
    set :href_class, "console-brand"
    set :image_url, nil
    set :dark_image_url, nil
    set :image_class, nil
    set :dark_image_class, nil
    set :text, "Overalls"
    set :text_class, "console-brand"
  end

  override Components.HorizontalRule do
    set :root_class, "auth-rule"
    set :hr_outer_class, nil
    set :hr_inner_class, nil
    set :text_outer_class, "muted"
    set :text_inner_class, nil
  end

  override Components.Flash do
    set :message_class_info, "flash auth-flash"
    set :message_class_error, "flash auth-flash"
  end

  # The welcome heading already names the product, so the panel has no banner.
  override Components.SignIn do
    set :show_banner, false
    set :root_class, "auth-panel"
    set :strategy_class, "stack"
    set :authentication_error_container_class, "error"
    set :authentication_error_text_class, nil
    set :dev_mailbox_container_class, "muted"
    set :dev_mailbox_link_class, nil
  end

  override Components.Confirm do
    set :show_banner, false
    set :root_class, "auth-panel"
    set :strategy_class, "stack"
  end

  override Components.Confirm.Input do
    set :submit_class, "console-button primary"
  end

  override Components.SignOut do
    set :root_class, "auth-panel"
    set :h2_class, "ident"
    set :info_text_class, "muted"
    set :form_class, nil
    set :button_class, "console-button primary"
  end

  override Components.MagicLink.Input do
    set :submit_class, "console-button primary"
    set :submit_label, "Sign in"
    set :remember_me_class, "field inline"
    set :checkbox_class, nil
    set :checkbox_label_class, nil
  end

  override Components.Password.Input do
    set :field_class, "field"
    set :label_class, "field-label"
    set :input_class, "console-input"
    set :input_class_with_error, "console-input invalid"
    set :submit_class, "console-button primary"
    set :error_ul, "error"
    set :error_li, nil
    set :remember_me_class, "field inline"
    set :checkbox_class, nil
    set :checkbox_label_class, nil
    set :password_field_wrapper_class, nil
    set :password_toggle_class, "console-button compact"
    set :password_toggle_icon_class, nil
  end

  # @cc [owner:ghuntley,label:security] registration-message-no-enumeration
  # Request feedback MUST avoid organization/domain requirements and MUST NOT
  # reveal account existence or mail-provider results.
  override Components.MagicLink do
    set :root_class, "stack"
    set :label_class, "ident"
    set :form_class, "stack"

    set :request_flash_text, @magic_link_request_feedback
  end
end
