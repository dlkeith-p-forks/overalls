defmodule Marshall.Mailer.LogFilterTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen

  # @cc [owner:ghuntley,label:security;verification] galileo-refusal-private-diagnostics
  # Only the exact authorization-denied event and its reviewed reason atoms may
  # retain a reason in authentication-tagged logs. Arbitrary payloads, other
  # events and mail-tagged events MUST retain the stronger redaction boundary.
  property "Galileo refusal reasons survive authentication filtering without private payloads" do
    check all(
            secret <- binary(min_length: 1, max_length: 512),
            reason <-
              member_of([
                :unauthorized,
                :invalid_request,
                :peer_unreachable,
                :authorization_invalid
              ])
          ) do
      event = %{
        msg: {:report, %{state: secret, token: secret}},
        meta: %{
          marshall_authentication: true,
          event: "galileo.authorization_denied",
          reason: reason,
          token: secret,
          unsafe: secret
        }
      }

      filtered = Marshall.Mailer.LogFilter.filter(event, nil)
      assert filtered.meta == %{event: "galileo.authorization_denied", reason: reason}
      assert filtered.msg == {:string, "Authentication process diagnostic (payload redacted)"}

      for unsafe <- [secret, {:error, secret}, %{reason: secret}, :unexpected, "unauthorized"] do
        redacted = Marshall.Mailer.LogFilter.filter(put_in(event.meta.reason, unsafe), nil)
        assert redacted.meta == %{event: "galileo.authorization_denied"}
        assert redacted.msg == filtered.msg
      end

      for other <- ["galileo.integration_configured", "account.deleted", "unknown.event"] do
        redacted = Marshall.Mailer.LogFilter.filter(put_in(event.meta.event, other), nil)
        # An undeclared reason never survives; a catalogued name gets only its
        # fixed catalog message, an unknown name stays fully redacted.
        assert redacted.meta == %{event: other}

        case Map.fetch(Marshall.Events.__catalog__(), other) do
          {:ok, %{message: message}} -> assert redacted.msg == {:string, message}
          :error -> assert redacted.msg == filtered.msg
        end
      end

      mail = put_in(event.meta[:marshall_mail], true)
      redacted = Marshall.Mailer.LogFilter.filter(mail, nil)
      assert redacted.meta == %{event: "galileo.authorization_denied"}
      assert redacted.msg == {:string, "Mail process diagnostic (payload redacted)"}
    end
  end

  # @cc [owner:ghuntley,label:security;verification] audi-unavailable-private-diagnostics
  # Authentication-tagged Audi control-unavailable events may retain only the
  # closed reason classes; arbitrary terms, strings and mail-tagged events MUST
  # keep full redaction.
  property "Audi unavailable reason classes survive authentication filtering alone" do
    check all(
            secret <- binary(min_length: 1, max_length: 512),
            reason <- member_of(Marshall.Mailer.LogFilter.control_reasons())
          ) do
      event = %{
        level: :error,
        msg: {:report, %{token: secret}},
        meta: %{
          marshall_authentication: true,
          event: "audi.control_unavailable",
          reason: reason,
          token: secret
        }
      }

      filtered = Marshall.Mailer.LogFilter.filter(event, nil)
      assert filtered.meta == %{event: "audi.control_unavailable", reason: reason}

      for unsafe <- [secret, {:error, secret}, :unauthorized_extra, "unavailable"] do
        redacted = Marshall.Mailer.LogFilter.filter(put_in(event.meta.reason, unsafe), nil)
        assert redacted.meta == %{event: "audi.control_unavailable"}
      end

      mail = put_in(event.meta[:marshall_mail], true)

      assert Marshall.Mailer.LogFilter.filter(mail, nil).meta == %{
               event: "audi.control_unavailable"
             }
    end
  end

  property "tagged diagnostics cannot retain arbitrary provider payloads or state" do
    check all(secret <- binary(min_length: 1, max_length: 512)) do
      event = %{
        level: :error,
        msg: {:report, %{state: secret, reason: secret}},
        meta: %{
          marshall_mail: true,
          request_id: "request",
          delivery_id: "delivery",
          delivery_status: :failed,
          unsafe: secret
        }
      }

      filtered = Marshall.Mailer.LogFilter.filter(event, nil)
      assert filtered.msg == {:string, "Mail process diagnostic (payload redacted)"}
      assert filtered.meta == %{}
      assert filtered.level == :error
    end
  end

  property "tagged catalog events keep only validated correlation keys while tokens never survive" do
    check all(secret <- binary(min_length: 1, max_length: 512)) do
      event = %{
        level: :info,
        msg: {:string, "provider said " <> secret},
        meta: %{
          marshall_authentication: true,
          event: "account.deleted",
          user_id: "8cf65a48-6e93-4b8e-93bd-6bd0f4dc3a28",
          actor_id: "90c1a5a0-1111-4d67-9ef9-b31bd8e0fe14",
          unsafe: secret,
          token: secret
        }
      }

      filtered = Marshall.Mailer.LogFilter.filter(event, nil)

      # The catalog's fixed message replaces the call's text.
      assert filtered.msg == {:string, "Account deleted"}

      assert filtered.meta == %{
               event: "account.deleted",
               user_id: "8cf65a48-6e93-4b8e-93bd-6bd0f4dc3a28",
               actor_id: "90c1a5a0-1111-4d67-9ef9-b31bd8e0fe14"
             }
    end
  end

  # @cc [owner:ghuntley,label:verification;security] auth-filter-catalogued-metadata
  # A catalogued event emitted in an authentication-tagged process MUST keep
  # its declared, type-valid metadata (so failures stay diagnosable) and MUST
  # drop strings under declared keys, undeclared keys and any token.
  property "catalogued events keep declared typed metadata; payloads never survive" do
    check all(
            payload <- binary(min_length: 1, max_length: 256),
            reason <- member_of([:restart_failed, :physical_state_unconfirmed, :other]),
            string_reason? <- boolean()
          ) do
      vm_id = "8cf65a48-6e93-4b8e-93bd-6bd0f4dc3a28"
      secret = "PRIVATE-PAYLOAD-" <> Base.encode16(payload)

      event = %{
        level: :warning,
        msg: {:string, "VM resize failed " <> secret},
        meta: %{
          marshall_authentication: true,
          request_id: secret,
          event: "vm.resize_failed",
          vm_id: vm_id,
          reason: if(string_reason?, do: secret, else: reason),
          token: secret,
          unsafe: secret
        }
      }

      filtered = Marshall.Mailer.LogFilter.filter(event, nil)
      assert filtered.msg == {:string, "VM resize failed"}

      expected = %{event: "vm.resize_failed", vm_id: vm_id}
      expected = if string_reason?, do: expected, else: Map.put(expected, :reason, reason)
      assert filtered.meta == expected
      refute inspect(filtered) =~ secret
    end
  end

  test "restricted catalogued events never widen their reviewed reasons" do
    event = %{
      level: :warning,
      msg: {:string, "x"},
      meta: %{
        marshall_authentication: true,
        event: "galileo.authorization_denied",
        reason: :unreviewed_reason
      }
    }

    filtered = Marshall.Mailer.LogFilter.filter(event, nil)
    refute Map.has_key?(filtered.meta, :reason)
    assert filtered.msg == {:string, "Authentication process diagnostic (payload redacted)"}
  end
end
