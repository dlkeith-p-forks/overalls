defmodule Marshall.MessageBoards.Domain do
  @moduledoc "Resource ownership for account/profile message boards and machine-scoped posts."
  use Ash.Domain, otp_app: :marshall

  resources do
    resource Marshall.MessageBoards.Board
    resource Marshall.MessageBoards.Post
  end
end
