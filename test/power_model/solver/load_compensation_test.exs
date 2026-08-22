defmodule PowerModel.Solver.LoadCompensationTest do
  @moduledoc """
  Distribution reactive compensation on the load model.

  The network modelled every transmission-to-distribution interface at a 0.95
  power factor, which no real interface runs at — distribution carries its own
  capacitors and utilities hold the interface near unity. The physical content
  of modelling that as a V^2 term rather than simply raising the loads' power
  factor is what these tests pin: net reactive draw has to RISE into a voltage
  sag, because the compensation fades as V^2 while the load it offsets does
  not.
  """
  use ExUnit.Case, async: true

  alias PowerModel.Solver.{LoadModel, NewtonRaphson, DCPowerFlow, Solution}

  @q_over_p 0.3287  # tan(acos(0.95)), the ratio the load estimator synthesizes

  defp load(p, q, type \\ "constant_power"), do: %{p_mw: p, q_mvar: q, load_type: type}

  describe "the compensation fraction is derived, not tuned" do
    test "k reproduces the target interface power factor at nominal voltage" do
      k = LoadModel.compensation_fraction()
      p = 100.0
      q0 = p * @q_over_p

      {^p, q_net} = LoadModel.effective_load(load(p, q0), 1.0)

      implied_pf = :math.cos(:math.atan(q_net / p))

      assert_in_delta implied_pf, LoadModel.interface_pf(), 1.0e-4
      assert_in_delta k, 1.0 - :math.tan(:math.acos(LoadModel.interface_pf())) / :math.tan(:math.acos(0.95)), 1.0e-9
    end

    test "the shipped target sits inside the 0.95-to-unity band" do
      # 0.95 is the conventional penalty threshold in power-factor tariffs, not
      # an operating target; unity is the limit distribution compensation aims
      # at. Anything outside that band would not be defensible.
      assert LoadModel.interface_pf() > 0.95
      assert LoadModel.interface_pf() <= 1.0
      assert LoadModel.compensation_fraction() > 0.0
      assert LoadModel.compensation_fraction() <= 1.0
    end
  end

  describe "the V^2 fade is the point" do
    test "net reactive draw RISES as the bus sags" do
      l = load(100.0, 32.87)

      {_p, q_nominal} = LoadModel.effective_load(l, 1.0)
      {_p, q_sagged} = LoadModel.effective_load(l, 0.9)
      {_p, q_floor} = LoadModel.effective_load(l, 0.5)

      assert q_sagged > q_nominal
      assert q_floor > q_sagged
    end

    test "a constant-power load with compensation is NOT flat in voltage" do
      # Without compensation a constant_power load draws the same Q at every
      # voltage, which is what made the ZIP machinery inert on this database.
      l = load(100.0, 32.87)

      {_p1, q1} = LoadModel.effective_load(l, 1.0)
      {_p2, q2} = LoadModel.effective_load(l, 0.8)

      refute_in_delta q1, q2, 1.0e-6
    end

    test "real power is untouched by compensation" do
      # A capacitor bank is reactive-only; if this ever fails the term has been
      # applied to the wrong side.
      l = load(100.0, 32.87)

      for v <- [0.5, 0.8, 1.0, 1.2] do
        {p, _q} = LoadModel.effective_load(l, v)
        assert_in_delta p, 100.0, 1.0e-9
      end
    end

    test "the fade is quantitatively V^2" do
      k = LoadModel.compensation_fraction()
      q0 = 32.87
      l = load(100.0, q0)
      v = 0.7

      {_p, q_net} = LoadModel.effective_load(l, v)

      assert_in_delta q_net, q0 - k * q0 * v * v, 1.0e-9
    end

    test "a load with zero reactive demand gets no compensation" do
      assert {100.0, +0.0} = LoadModel.effective_load(load(100.0, 0.0), 0.8)
    end

    test "a nil q_mvar does not raise" do
      assert {100.0, +0.0} = LoadModel.effective_load(%{p_mw: 100.0, load_type: nil}, 0.9)
    end
  end

  describe "the voltage dependence follows the DEVICE, not the load" do
    # A distribution feeder's banks are passive and fade as V^2. A datacenter
    # campus is built from power-factor-corrected PSU/UPS rectifiers, which are
    # controlled converters holding near-unity input pf across their operating
    # range — their correction does not fade. Giving a campus the passive
    # treatment overstates its reactive draw in a sag.
    test "a datacenter holds a CONSTANT power factor across voltage" do
      dc = load(900.0, 900.0 * @q_over_p, "datacenter")

      pf_at = fn v ->
        {p, q} = LoadModel.effective_load(dc, v)
        :math.cos(:math.atan(q / p))
      end

      assert_in_delta pf_at.(1.0), pf_at.(0.85), 1.0e-9
      assert_in_delta pf_at.(1.0), pf_at.(1.1), 1.0e-9
      assert_in_delta pf_at.(1.0), LoadModel.interface_pf(), 1.0e-4
    end

    test "a distribution feeder's power factor DEGRADES as it sags" do
      feeder = load(900.0, 900.0 * @q_over_p)

      pf_at = fn v ->
        {p, q} = LoadModel.effective_load(feeder, v)
        :math.cos(:math.atan(q / p))
      end

      assert pf_at.(0.85) < pf_at.(1.0)
    end

    test "the two agree at nominal and diverge below it" do
      q0 = 900.0 * @q_over_p
      feeder = load(900.0, q0)
      dc = load(900.0, q0, "datacenter")

      {_p1, q_feeder_nom} = LoadModel.effective_load(feeder, 1.0)
      {_p2, q_dc_nom} = LoadModel.effective_load(dc, 1.0)
      assert_in_delta q_feeder_nom, q_dc_nom, 1.0e-9

      {_p3, q_feeder_sag} = LoadModel.effective_load(feeder, 0.9)
      {_p4, q_dc_sag} = LoadModel.effective_load(dc, 0.9)

      # The passive treatment draws measurably more reactive power in the sag.
      assert q_feeder_sag > q_dc_sag
      assert_in_delta q_feeder_sag / q_dc_sag, 1.118, 0.01
    end

    test "the datacenter ZIP must stay constant-power, or the active form leaks voltage dependence" do
      # The active-front-end form is `k*Q0*zip_factor(V)`, which gives a
      # constant power factor ONLY because the datacenter ZIP is pure constant
      # power — and it is so by falling through the catch-all clause, not by an
      # explicit one. If someone later gives datacenters a Z or I component
      # (cooling load is a plausible reason), Q would inherit a voltage
      # dependence through the back door and quietly reintroduce a smaller
      # version of the passive behaviour this split removed. Fail loudly here
      # so that becomes a conscious decision about the compensation too.
      assert LoadModel.zip_coefficients("datacenter") == %{z: 0.0, i: 0.0, p: 1.0}
      assert LoadModel.zip_factor("datacenter", 0.8) == 1.0
    end

    test "dq_load_dv matches a finite difference for a datacenter too" do
      dc = load(900.0, 900.0 * @q_over_p, "datacenter")
      v = 0.93
      h = 1.0e-6

      {_p1, q1} = LoadModel.effective_load(dc, v - h)
      {_p2, q2} = LoadModel.effective_load(dc, v + h)

      assert_in_delta LoadModel.dq_load_dv(dc, v), (q2 - q1) / (2 * h), 1.0e-5
    end

    test "a constant-power datacenter has zero reactive voltage sensitivity" do
      dc = load(900.0, 900.0 * @q_over_p, "datacenter")

      assert_in_delta LoadModel.dq_load_dv(dc, 0.9), 0.0, 1.0e-9
    end
  end

  describe "compensation is shed with its load" do
    test "a fully shed load carries no compensation" do
      # cascade.ex zeroes p_mw and q_mvar on a lost bus. Keying compensation
      # off the live q_mvar is what makes it vanish with the feeders instead of
      # stranding capacitance in a collapsing island — the whole reason this
      # lives on the load and not in buses.bs_mvar.
      assert {+0.0, +0.0} = LoadModel.effective_load(load(0.0, 0.0), 0.85)
    end

    test "a partially shed load keeps compensation in proportion" do
      # load_shedding.ex scales p_mw and q_mvar by the same (1 - fraction).
      full = load(100.0, 32.87)
      half = load(50.0, 32.87 * 0.5)
      v = 0.92

      {_pf, q_full} = LoadModel.effective_load(full, v)
      {_ph, q_half} = LoadModel.effective_load(half, v)

      assert_in_delta q_half, q_full / 2.0, 1.0e-9
    end
  end

  describe "the Jacobian sensitivity" do
    test "dq_load_dv matches a finite difference" do
      l = load(100.0, 32.87)
      v = 0.93
      h = 1.0e-6

      {_p1, q1} = LoadModel.effective_load(l, v - h)
      {_p2, q2} = LoadModel.effective_load(l, v + h)

      assert_in_delta LoadModel.dq_load_dv(l, v), (q2 - q1) / (2 * h), 1.0e-5
    end

    test "dp_load_dv matches a finite difference for a ZIP load" do
      l = load(100.0, 32.87, "residential")
      v = 0.93
      h = 1.0e-6

      {p1, _q1} = LoadModel.effective_load(l, v - h)
      {p2, _q2} = LoadModel.effective_load(l, v + h)

      assert_in_delta LoadModel.dp_load_dv(l, v), (p2 - p1) / (2 * h), 1.0e-5
    end

    test "dq_load_dv is NONZERO for a constant-power load" do
      # The regression this guards: the old sensitivity skipped a load whenever
      # the ZIP factor derivative was zero, which is every load in this
      # database. That path would silently drop compensation from the Jacobian.
      l = load(100.0, 32.87)

      assert LoadModel.dfactor_dv(l.load_type, 0.9) == 0.0
      assert LoadModel.dq_load_dv(l, 0.9) < 0.0
    end
  end

  describe "the solvers" do
    defp two_bus do
      %{
        buses: [
          %{id: 1, bus_type: 3, base_kv: 138.0, bs_mvar: 0.0, gs_mw: 0.0},
          %{id: 2, bus_type: 1, base_kv: 138.0, bs_mvar: 0.0, gs_mw: 0.0}
        ],
        lines: [
          %{
            id: 1,
            from_bus_id: 1,
            to_bus_id: 2,
            voltage_kv: 138.0,
            r_pu: 0.01,
            x_pu: 0.10,
            b_pu: 0.02,
            rating_a_mva: 400.0
          }
        ],
        transformers: [],
        generators: [
          %{
            id: 1,
            bus_id: 1,
            p_max_mw: 200.0,
            capacity_factor: 1.0,
            q_max_mvar: 400.0,
            q_min_mvar: -400.0
          }
        ],
        loads: [load(150.0, 150.0 * @q_over_p) |> Map.merge(%{id: 1, bus_id: 2})]
      }
    end

    test "AC converges and the compensated bus sits higher than an uncompensated one" do
      {:ok, sol} = NewtonRaphson.solve(two_bus(), base_mva: 100.0, tolerance: 1.0e-10)
      assert sol.converged

      vm = fn s -> Enum.at(s.vm_pu, Enum.find_index(s.bus_ids, &(&1 == 2))) end

      # Same case with the compensation manually removed by grossing the load
      # DOWN to the net it would present at unity voltage: compensation both
      # raises the voltage and, unlike a flat pf change, keeps a V-dependence.
      k = LoadModel.compensation_fraction()
      uncompensated = two_bus()
      raw_q = 150.0 * @q_over_p

      heavier =
        put_in(uncompensated.loads, [%{uncompensated |> Map.get(:loads) |> hd() | q_mvar: raw_q / (1.0 - k)}])

      {:ok, sol2} = NewtonRaphson.solve(heavier, base_mva: 100.0, tolerance: 1.0e-10)
      assert sol2.converged
      assert vm.(sol) > vm.(sol2)
    end

    test "the DC path is untouched" do
      # DC assumes V = 1.0 and reads no reactive quantity at all, so a change
      # that is purely reactive must leave every DC number identical.
      a = DCPowerFlow.solve(two_bus(), base_mva: 100.0)

      zero_q = update_in(two_bus().loads, fn [l] -> [%{l | q_mvar: 0.0}] end)
      b = DCPowerFlow.solve(zero_q, base_mva: 100.0)

      assert a.va_rad == b.va_rad

      assert Solution.line_flow(a, :line, 1).p_flow_mw ==
               Solution.line_flow(b, :line, 1).p_flow_mw
    end
  end
end
