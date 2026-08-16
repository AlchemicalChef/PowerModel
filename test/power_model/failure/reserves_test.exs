defmodule PowerModel.Failure.ReservesTest do
  @moduledoc """
  Ramp-limited reserve tiers (ROADMAP item 16).

  The property under test throughout: reserve is a RATE, not a quantity. Two
  fleets with identical nameplate headroom deliver wildly different megawatts
  in the first ten seconds of a contingency, and the difference is what
  decides whether an island sheds customers.
  """
  use ExUnit.Case, async: true

  alias PowerModel.Failure.Reserves
  alias PowerModel.Solver.Frequency

  # A unit at a chosen operating point, in the shape the cascade hands around
  # (`p_dispatch_mw` is the SUSTAINED output, `p_nameplate_mw` the machine).
  defp unit(id, fuel, nameplate, dispatched) do
    %{
      id: id,
      fuel_type: fuel,
      p_max_mw: dispatched,
      capacity_factor: 1.0,
      p_dispatch_mw: dispatched,
      p_nameplate_mw: nameplate
    }
  end

  describe "primary tier" do
    test "is the frequency model's own capability, and only for spinning units" do
      gas = unit(1, "NG", 1000.0, 900.0)

      assert Reserves.primary_capability_mw(gas) ==
               Frequency.primary_response_capability_mw(gas)

      # 1%/s over the 10 s nadir window, capped by the 100 MW of headroom.
      assert_in_delta Reserves.primary_capability_mw(gas), 100.0, 1.0e-9

      # An unsynchronised machine has a governor and nothing to move with it.
      assert Reserves.primary_capability_mw(unit(2, "NG", 1000.0, 0.0)) == 0.0

      # Nuclear is online, has headroom, and answers nothing.
      assert Reserves.primary_capability_mw(unit(3, "NUC", 1000.0, 800.0)) == 0.0
    end

    test "fills only what the sustained tiers could not reach in time" do
      # Ten minutes in, secondary can cover the whole deficit on its own, so
      # the governors are not asked for anything: primary arrests, secondary
      # replaces.
      units = [unit(1, "NG", 1000.0, 500.0)]

      immediate = Reserves.allocate(units, 200.0, 0.0)
      assert immediate.secondary_mw == 0.0
      assert_in_delta immediate.primary_mw, 100.0, 1.0e-9
      assert_in_delta immediate.remaining_mw, 100.0, 1.0e-9

      later = Reserves.allocate(units, 200.0, 600.0)
      assert_in_delta later.secondary_mw, 200.0, 1.0e-9
      assert later.primary_mw == 0.0
      assert later.remaining_mw == 0.0
    end
  end

  describe "secondary tier" do
    test "delivers the technology ramp over the elapsed clock, nothing more" do
      # 8%/min on 1000 MW of nameplate is 80 MW/min: half a minute buys 40 MW,
      # however much headroom is idle behind it.
      gas = unit(1, "NG", 1000.0, 200.0)

      assert_in_delta Reserves.secondary_capability_mw(gas, 30.0), 40.0, 1.0e-9
      assert_in_delta Reserves.secondary_capability_mw(gas, 60.0), 80.0, 1.0e-9
      assert Reserves.secondary_capability_mw(gas, 0.0) == 0.0

      # ...and never more than the headroom itself: 800 MW is reached at ten
      # minutes and the tier stops there, whatever the clock says.
      assert_in_delta Reserves.secondary_capability_mw(gas, 600.0), 800.0, 1.0e-9
    end

    test "is not available from a unit that is not running" do
      assert Reserves.secondary_capability_mw(unit(1, "NG", 1000.0, 0.0), 600.0) == 0.0
    end

    test "an unbounded clock is the operating point, not an event" do
      # `:infinity` is what `Cascade.init/3` uses to close the base operating
      # point's own gap: no event happened, so no ramp limit applies.
      gas = unit(1, "NG", 1000.0, 200.0)
      assert_in_delta Reserves.secondary_capability_mw(gas, :infinity), 800.0, 1.0e-9
    end
  end

  describe "tertiary tier" do
    test "waits for the start-up delay, then ramps like any machine" do
      %{tertiary_delay_s: delay} = Reserves.horizons()
      idle = unit(1, "NG", 1000.0, 0.0)

      assert Reserves.tertiary_capability_mw(idle, delay) == 0.0
      assert_in_delta Reserves.tertiary_capability_mw(idle, delay + 60.0), 80.0, 1.0e-9
    end

    test "is only reached once secondary has saturated" do
      # A spinning unit with 30 MW of reachable secondary and an idle unit
      # beside it: at 20 minutes the idle unit could contribute, but the
      # deficit is small enough that spinning reserve answers it alone.
      units = [unit(1, "NG", 100.0, 70.0), unit(2, "NG", 1000.0, 0.0)]

      small = Reserves.allocate(units, 10.0, 1200.0)
      assert_in_delta small.secondary_mw, 10.0, 1.0e-9
      assert small.tertiary_mw == 0.0

      # A deficit past the spinning fleet's reach starts the idle machine.
      large = Reserves.allocate(units, 400.0, 1200.0)
      assert_in_delta large.secondary_mw, 30.0, 1.0e-9
      assert large.tertiary_mw > 0.0
    end
  end

  describe "the same headroom, two technologies" do
    test "a slow fleet cannot deliver in ten seconds what a fast one can" do
      # Identical machines, identical headroom, identical instant.
      coal = Reserves.allocate([unit(1, "BIT", 1000.0, 500.0)], 400.0, 0.0)
      gas = Reserves.allocate([unit(1, "NG", 1000.0, 500.0)], 400.0, 0.0)
      hydro = Reserves.allocate([unit(1, "WAT", 1000.0, 500.0)], 400.0, 0.0)

      assert_in_delta coal.primary_mw, 20.0, 1.0e-9
      assert_in_delta gas.primary_mw, 100.0, 1.0e-9
      assert_in_delta hydro.primary_mw, 150.0, 1.0e-9

      # Every one of them has 500 MW of nameplate headroom.
      assert coal.remaining_mw > gas.remaining_mw
      assert gas.remaining_mw > hydro.remaining_mw
    end

    test "and the gap closes as the clock runs" do
      coal = unit(1, "BIT", 1000.0, 500.0)
      hydro = unit(2, "WAT", 1000.0, 500.0)

      for elapsed <- [30.0, 120.0, 600.0] do
        assert Reserves.secondary_capability_mw(coal, elapsed) <=
                 Reserves.secondary_capability_mw(hydro, elapsed)
      end

      # At the ten-minute secondary horizon hydro has reached its headroom and
      # coal is still a quarter of the way there — 2%/min against 25%/min.
      assert_in_delta Reserves.secondary_capability_mw(hydro, 600.0), 500.0, 1.0e-9
      assert_in_delta Reserves.secondary_capability_mw(coal, 600.0), 200.0, 1.0e-9

      # Coal gets the rest through the tertiary tier, on the same ramp over
      # the longer clock: reserve it can only reach in half an hour is not
      # contingency reserve.
      assert_in_delta Reserves.tertiary_capability_mw(coal, 1500.0), 300.0, 1.0e-9
    end
  end

  describe "allocation shape" do
    test "shares each tier out in proportion to what each unit can deliver" do
      units = [unit(1, "NG", 1000.0, 500.0), unit(2, "NG", 2000.0, 1000.0)]
      alloc = Reserves.allocate(units, 90.0, 0.0)

      # Capability is 100 and 200 MW, so the 90 MW splits 30/60.
      assert_in_delta Map.fetch!(alloc.primary_by_unit, 1), 30.0, 1.0e-9
      assert_in_delta Map.fetch!(alloc.primary_by_unit, 2), 60.0, 1.0e-9
      assert alloc.remaining_mw == 0.0
    end

    test "reports what each tier COULD have delivered, used or not" do
      alloc = Reserves.allocate([unit(1, "NG", 1000.0, 500.0)], 10.0, 600.0)

      assert_in_delta alloc.secondary_mw, 10.0, 1.0e-9
      assert_in_delta alloc.secondary_capability_mw, 500.0, 1.0e-9
      assert alloc.primary_capability_mw > 0.0
    end

    test "an empty fleet or a closed deficit allocates nothing" do
      assert Reserves.allocate([], 100.0, 600.0).remaining_mw == 100.0
      assert Reserves.allocate([unit(1, "NG", 1000.0, 500.0)], 0.0, 600.0).secondary_mw == 0.0
    end

    test "total primary-capable reserve is the sum the requirement is written against" do
      units = [
        unit(1, "NG", 1000.0, 900.0),
        unit(2, "NUC", 1000.0, 800.0),
        unit(3, "WAT", 400.0, 300.0)
      ]

      # Gas 100 (headroom-capped), nuclear 0 (no duty), hydro 60 (rate-capped).
      assert_in_delta Reserves.primary_capability_mw_total(units), 160.0, 1.0e-9
    end
  end

  describe "the secondary tier's source" do
    # The tiers here are OPEN-LOOP: what the clock allowed, delivered against
    # an arithmetic deficit. `PowerModel.Controls.AGC` is the closed loop, and
    # `allocate/4` lets it REPLACE this tier — never join it. The AGC-side
    # behaviour is covered in `PowerModel.Controls.AGCTest`; what is pinned
    # here is that Reserves' own contract did not move.

    test "defaults to the clock, and the three-argument call is unchanged" do
      units = [unit(1, "NG", 1000.0, 500.0)]

      assert Reserves.allocate(units, 100.0, 600.0) ==
               Reserves.allocate(units, 100.0, 600.0, [])

      assert Reserves.allocate(units, 100.0, 600.0, secondary: :clock) ==
               Reserves.allocate(units, 100.0, 600.0)

      assert Reserves.allocate(units, 100.0, 600.0).secondary_source == :clock
      assert Reserves.secondary_capability_mw(hd(units), 600.0) == 500.0
    end

    test "an AGC-fed tier delivers AGC's megawatts, capped by physical headroom" do
      units = [unit(1, "NG", 1000.0, 500.0), unit(2, "NG", 1000.0, 950.0)]

      # AGC asks for 120 MW from unit 1 and 200 MW from unit 2 — but unit 2
      # only has 50 MW of headroom, and the physical limit is the one both
      # sides must agree on.
      alloc =
        Reserves.allocate(units, 400.0, 600.0, secondary: {:agc, %{1 => 120.0, 2 => 200.0}})

      assert alloc.secondary_source == :agc
      assert_in_delta alloc.secondary_capability_mw, 170.0, 1.0e-9
      assert_in_delta Map.fetch!(alloc.sustained_by_unit, 2), 50.0, 1.0e-9
    end

    test "a unit AGC did not raise contributes no secondary reserve at all" do
      units = [unit(1, "NG", 1000.0, 500.0), unit(2, "NG", 1000.0, 500.0)]

      alloc = Reserves.allocate(units, 400.0, 600.0, secondary: {:agc, %{1 => 60.0}})

      assert_in_delta alloc.secondary_mw, 60.0, 1.0e-9
      refute Map.has_key?(alloc.sustained_by_unit, 2)

      # The clocked tier would have offered both units their whole headroom:
      # this is the tier being REPLACED, not supplemented.
      assert Reserves.allocate(units, 400.0, 600.0).secondary_mw == 400.0
    end

    test "an unsynchronised machine is not on AGC however much it is offered" do
      offline = unit(1, "NG", 1000.0, 0.0)

      assert Reserves.secondary_capability_mw(offline, 600.0, {:agc, %{1 => 500.0}}) == 0.0
    end

    test "tertiary stays on the clock while secondary is closed-loop" do
      units = [unit(1, "BIT", 1000.0, 500.0)]
      deltas = %{1 => 40.0}

      # Inside the start-up delay there is no tertiary in either mode.
      assert Reserves.allocate(units, 500.0, 60.0, secondary: {:agc, deltas}).tertiary_capability_mw ==
               0.0

      # Past it the tier ramps on elapsed time exactly as it always did: 15
      # minutes of coal's 2%/min is 300 MW, and the clock is still what binds.
      late = Reserves.allocate(units, 500.0, 1500.0, secondary: {:agc, deltas})
      assert_in_delta late.tertiary_capability_mw, 300.0, 1.0e-9

      # Once the ramp has run long enough for headroom to bind instead, the
      # 40 MW AGC already took is deducted — the two tiers draw on one pool.
      later = Reserves.allocate(units, 500.0, 2400.0, secondary: {:agc, deltas})
      assert_in_delta later.tertiary_capability_mw, 460.0, 1.0e-9
    end
  end
end
