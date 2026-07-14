defmodule Tabletap.StaffingTest do
  use Tabletap.DataCase, async: true
  use Oban.Testing, repo: Tabletap.ObanRepo

  import Tabletap.TenantsFixtures

  alias Tabletap.Accounts.Scope
  alias Tabletap.Staffing
  alias Tabletap.Staffing.Shift
  alias Tabletap.Staffing.Workers.AutoCloseShifts

  setup do
    %{org: org, venue: venue} = org_fixture()
    Repo.put_org_id(org.id)
    %{membership: membership} = waiter_fixture(org, venue)
    scope = %Scope{org: org, venue: venue, membership: membership, role: :waiter}

    %{scope: scope, org: org, venue: venue, membership: membership}
  end

  describe "clock_in/1 and clock_out/1" do
    test "clocking in opens a shift; clocking out closes it", %{
      scope: scope,
      membership: membership
    } do
      assert {:ok, shift} = Staffing.clock_in(scope)
      assert shift.membership_id == membership.id
      assert shift.ended_at == nil
      assert Staffing.on_shift?(membership.id)

      assert {:ok, closed} = Staffing.clock_out(scope)
      assert closed.ended_at
      refute closed.auto_closed
      refute Staffing.on_shift?(membership.id)
    end

    test "a second clock-in while already on shift is rejected", %{scope: scope} do
      {:ok, _} = Staffing.clock_in(scope)
      assert {:error, :already_clocked_in} = Staffing.clock_in(scope)
    end

    test "clocking out without an open shift is rejected", %{scope: scope} do
      assert {:error, :not_clocked_in} = Staffing.clock_out(scope)
    end
  end

  describe "list_on_shift_waiter_membership_ids/1" do
    test "only on-shift, active waiter memberships count", %{
      scope: scope,
      org: org,
      venue: venue,
      membership: membership
    } do
      # A second waiter who never clocks in.
      %{membership: _off_shift} = waiter_fixture(org, venue)
      {:ok, _} = Staffing.clock_in(scope)

      assert Staffing.list_on_shift_waiter_membership_ids(venue.id) == [membership.id]
    end

    test "a deactivated membership stops counting even with an open shift row", %{
      scope: scope,
      venue: venue,
      membership: membership
    } do
      {:ok, _} = Staffing.clock_in(scope)
      {:ok, _} = membership |> Ecto.Changeset.change(active: false) |> Repo.update()

      assert Staffing.list_on_shift_waiter_membership_ids(venue.id) == []
    end
  end

  describe "force_end_shift/2 (design-qa.md Q44)" do
    test "ends an open shift; a no-shift membership is a safe no-op", %{
      scope: scope,
      membership: membership
    } do
      assert {:ok, nil} = Staffing.force_end_shift(scope, membership)

      {:ok, _} = Staffing.clock_in(scope)
      assert {:ok, %Shift{ended_at: ended_at}} = Staffing.force_end_shift(scope, membership)
      assert ended_at
    end
  end

  describe "Workers.AutoCloseShifts (design-qa.md Q45)" do
    test "closes a shift whose business day has rolled over, flagged auto_closed", %{
      scope: scope
    } do
      {:ok, shift} = Staffing.clock_in(scope)

      # Backdate the shift start past the venue's business-day cutoff.
      two_days_ago = DateTime.add(DateTime.utc_now(:second), -2, :day)
      {:ok, _} = shift |> Ecto.Changeset.change(started_at: two_days_ago) |> Repo.update()

      assert :ok = perform_job(AutoCloseShifts, %{})

      closed = Repo.get(Shift, shift.id)
      assert closed.ended_at
      assert closed.auto_closed
    end

    test "a same-business-day shift stays open", %{scope: scope} do
      {:ok, shift} = Staffing.clock_in(scope)

      assert :ok = perform_job(AutoCloseShifts, %{})

      assert Repo.get(Shift, shift.id).ended_at == nil
    end
  end
end
