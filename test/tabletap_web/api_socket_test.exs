defmodule TabletapWeb.ApiSocketTest do
  use TabletapWeb.ChannelCase, async: true

  import Tabletap.AccountsFixtures

  alias TabletapWeb.{ApiAuth, ApiSocket}

  test "connects anonymously with no token" do
    assert {:ok, socket} = connect(ApiSocket, %{})
    assert socket.assigns.current_user == nil
  end

  test "connects and resolves current_user with a valid token" do
    user = user_fixture()
    token = ApiAuth.sign_access_token(user)

    assert {:ok, socket} = connect(ApiSocket, %{"token" => token})
    assert socket.assigns.current_user.id == user.id
  end

  test "rejects a present but invalid token outright" do
    assert :error = connect(ApiSocket, %{"token" => "garbage"})
  end
end
