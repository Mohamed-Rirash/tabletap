defmodule TabletapWeb.ScopeHooksTest do
  use TabletapWeb.ConnCase, async: true

  alias Phoenix.LiveView
  alias Tabletap.Accounts.Scope
  alias TabletapWeb.ScopeHooks

  defp bare_socket(assigns) do
    %LiveView.Socket{
      endpoint: TabletapWeb.Endpoint,
      assigns: Map.merge(%{__changed__: %{}, flash: %{}}, assigns)
    }
  end

  describe "on_mount :require_manager" do
    test "halts when there is no scope at all" do
      socket = bare_socket(%{current_scope: nil})

      assert {:halt, updated_socket} =
               ScopeHooks.on_mount(:require_manager, %{}, %{}, socket)

      assert Phoenix.Flash.get(updated_socket.assigns.flash, :error)
    end

    test "halts when the scope's role is nil (no membership resolved yet)" do
      socket = bare_socket(%{current_scope: %Scope{role: nil}})

      assert {:halt, _updated_socket} =
               ScopeHooks.on_mount(:require_manager, %{}, %{}, socket)
    end

    test "halts when the scope's role is not manager or owner" do
      socket = bare_socket(%{current_scope: %Scope{role: :waiter}})

      assert {:halt, _updated_socket} =
               ScopeHooks.on_mount(:require_manager, %{}, %{}, socket)
    end

    test "continues for a manager role" do
      socket = bare_socket(%{current_scope: %Scope{role: :manager}})

      assert {:cont, _updated_socket} =
               ScopeHooks.on_mount(:require_manager, %{}, %{}, socket)
    end

    test "continues for an owner role — owners can do everything a manager can" do
      socket = bare_socket(%{current_scope: %Scope{role: :owner}})

      assert {:cont, _updated_socket} =
               ScopeHooks.on_mount(:require_manager, %{}, %{}, socket)
    end
  end

  describe "on_mount :require_waiter" do
    test "does not admit a manager" do
      socket = bare_socket(%{current_scope: %Scope{role: :manager}})

      assert {:halt, _updated_socket} =
               ScopeHooks.on_mount(:require_waiter, %{}, %{}, socket)
    end

    test "admits a waiter" do
      socket = bare_socket(%{current_scope: %Scope{role: :waiter}})

      assert {:cont, _updated_socket} =
               ScopeHooks.on_mount(:require_waiter, %{}, %{}, socket)
    end
  end
end
