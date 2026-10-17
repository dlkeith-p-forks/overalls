defmodule Marshall.Accounts.EligibleEmail do
  @moduledoc "Bounded mailbox validation for account authentication actions."
  use Ash.Resource.Validation

  @impl true
  def supports(_opts), do: [Ash.Changeset, Ash.ActionInput]

  # @cc [owner:ghuntley,label:security] eligible-mailbox-and-public-error
  # Requests and verified-token identities MUST pass bounded mailbox validation,
  # regardless of domain or Linux-name eligibility. Errors MUST contain fixed text,
  # without Regex objects or recipient data in public interpolation variables.
  @impl true
  def validate(subject, _opts, _context) do
    email =
      case subject do
        %Ash.ActionInput{} -> Ash.ActionInput.get_argument(subject, :email)
        %Ash.Changeset{} -> Ash.Changeset.get_attribute(subject, :email)
      end

    if not is_nil(email) and
         Marshall.Accounts.EmailAddress.valid?(to_string(email)) do
      :ok
    else
      {:error, field: :email, message: "This email address is not eligible for sign-in."}
    end
  end
end
